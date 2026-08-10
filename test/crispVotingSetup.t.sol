// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IPluginSetup, PermissionLib} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {GovernanceERC20} from "@aragon/token-voting-plugin/erc20/GovernanceERC20.sol";
import {GovernanceWrappedERC20} from "@aragon/token-voting-plugin/erc20/GovernanceWrappedERC20.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {CrispVoting} from "../src/CrispVoting.sol";
import {CrispVotingSetup} from "../src/setup/CrispVotingSetup.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {IInterfold} from "../src/IInterfold.sol";

// --- Mocks -----------------------------------------------------------------

/// @dev Plain ERC20: has `balanceOf`, but none of the IVotes surface, so the setup
///      must wrap it in a `GovernanceWrappedERC20`.
contract MockPlainErc20 {
    mapping(address => uint256) public balanceOf;

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @dev IVotes-shaped token: used directly, never wrapped.
contract MockVotesErc20 {
    mapping(address => uint256) public balanceOf;

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 0;
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockInterfoldMinimal {
    function feeToken() external view returns (address) {
        return address(this);
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

// --- Tests -----------------------------------------------------------------

/// @notice Covers `CrispVotingSetup` — the install/uninstall permission surface.
///         These grants decide who can mint the governance token and who can execute on the DAO,
///         so they are the highest-consequence lines in the repo.
///
///         The plugin supports two install shapes, selected by the trailing `grantExecuteOnDao`
///         flag: a STANDALONE process (executes on the DAO itself) and a stage-0 BODY of a Staged
///         Proposal Processor (the SPP is the only executor). The tests below pin the difference.
contract CrispVotingSetupTest is Test {
    /// @dev Aragon's wildcard grantee. A permission granted here applies to EVERY address.
    address internal constant ANY_ADDR = address(type(uint160).max);

    DAO internal dao;
    CrispVotingSetup internal setup;
    MockInterfoldMinimal internal interfold;

    function setUp() public {
        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, (bytes(""), address(this), address(0), ""))
                ))
        );

        interfold = new MockInterfoldMinimal();

        setup = new CrispVotingSetup(
            new GovernanceERC20(
                IDAO(address(dao)), "base", "BASE", GovernanceERC20.MintSettings(new address[](0), new uint256[](0))
            ),
            new GovernanceWrappedERC20(IERC20Upgradeable(address(new MockPlainErc20())), "wbase", "WBASE"),
            address(new CrispVoting())
        );
    }

    function _params(address token) internal view returns (ICrispVoting.PluginInitParams memory params) {
        params = ICrispVoting.PluginInitParams({
            dao: IDAO(address(0)), // overwritten by the setup
            token: token, // overwritten by the setup
            interfold: address(interfold),
            committeeSize: IInterfold.CommitteeSize(0),
            paramSet: 0,
            crispProgramAddress: address(0xC0FFEE),
            computeProviderParams: bytes(""),
            votingSettings: ICrispVoting.VotingSettings({
                minProposerVotingPower: 0, minParticipation: 50, minDuration: 3600
            })
        });
    }

    function _encode(address tokenAddr, bool grantExecuteOnDao) internal view returns (bytes memory) {
        return abi.encode(
            _params(tokenAddr),
            CrispVotingSetup.TokenSettings({addr: tokenAddr, name: "Token", symbol: "TKN"}),
            GovernanceERC20.MintSettings({receivers: new address[](0), amounts: new uint256[](0)}),
            grantExecuteOnDao
        );
    }

    function _has(PermissionLib.MultiTargetPermission[] memory perms, address where, address who, bytes32 id)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < perms.length; i++) {
            if (perms[i].where == where && perms[i].who == who && perms[i].permissionId == id) return true;
        }
        return false;
    }

    // --- the two install shapes ---

    /// @dev A standalone process executes its own passed proposals, so it needs EXECUTE.
    function test_prepareInstallationGrantsExecuteForAStandaloneProcess() public {
        (address plugin, IPluginSetup.PreparedSetupData memory data) =
            setup.prepareInstallation(address(dao), _encode(address(new MockVotesErc20()), true));

        assertTrue(
            _has(data.permissions, address(dao), plugin, dao.EXECUTE_PERMISSION_ID()),
            "standalone process must be able to execute on the DAO"
        );
    }

    /// @dev THE invariant of the staged shape. A body holding EXECUTE would let a proposer execute
    ///      straight from stage 0 and skip every later stage, including a foundation veto.
    function test_prepareInstallationNeverGrantsExecuteToAnSppBody() public {
        (address plugin, IPluginSetup.PreparedSetupData memory data) =
            setup.prepareInstallation(address(dao), _encode(address(new MockVotesErc20()), false));

        assertFalse(
            _has(data.permissions, address(dao), plugin, dao.EXECUTE_PERMISSION_ID()),
            "an SPP body must NEVER hold EXECUTE on the DAO"
        );

        // Nothing else may sneak EXECUTE in via a different grantee either.
        for (uint256 i = 0; i < data.permissions.length; i++) {
            if (data.permissions[i].permissionId == dao.EXECUTE_PERMISSION_ID()) {
                fail();
            }
        }
    }

    /// @dev Without this the plugin cannot be re-pointed at the SPP's shared Executor, so its
    ///      `reportProposalResult` callback would not reach the SPP as the body — the staged
    ///      shape would be installable but non-functional.
    function test_prepareInstallationGrantsSetTargetConfigToTheDaoInBothShapes() public {
        bytes32 id = CrispVoting(setup.implementation()).SET_TARGET_CONFIG_PERMISSION_ID();

        (address bodyPlugin, IPluginSetup.PreparedSetupData memory bodyData) =
            setup.prepareInstallation(address(dao), _encode(address(new MockVotesErc20()), false));
        assertTrue(_has(bodyData.permissions, bodyPlugin, address(dao), id), "body: DAO must be able to re-target");

        (address soloPlugin, IPluginSetup.PreparedSetupData memory soloData) =
            setup.prepareInstallation(address(dao), _encode(address(new MockVotesErc20()), true));
        assertTrue(
            _has(soloData.permissions, soloPlugin, address(dao), id), "standalone: DAO must be able to re-target"
        );
    }

    // --- minting ---

    /// @dev Regression guard. This once granted MINT to ANY_ADDR "for testing", which let anyone
    ///      mint the governance token and manufacture voting power at will.
    function test_prepareInstallationGrantsMintToTheDaoOnlyNeverToAnyAddr() public {
        (, IPluginSetup.PreparedSetupData memory data) =
            setup.prepareInstallation(address(dao), _encode(address(0), true));

        bool sawMint;
        for (uint256 i = 0; i < data.permissions.length; i++) {
            bytes32 id = data.permissions[i].permissionId;
            if (id == GovernanceERC20(setup.governanceERC20Base()).MINT_PERMISSION_ID()) {
                sawMint = true;
                assertEq(data.permissions[i].who, address(dao), "mint must be granted to the DAO");
                assertTrue(data.permissions[i].who != ANY_ADDR, "mint must NEVER be granted to ANY_ADDR");
            }
        }
        assertTrue(sawMint, "a freshly deployed token must grant MINT to the DAO");
    }

    /// @dev An existing token is not ours to mint, so no mint permission is requested at all.
    function test_prepareInstallationRequestsNoMintPermissionForAnExistingToken() public {
        (, IPluginSetup.PreparedSetupData memory data) =
            setup.prepareInstallation(address(dao), _encode(address(new MockVotesErc20()), true));

        for (uint256 i = 0; i < data.permissions.length; i++) {
            assertTrue(
                data.permissions[i].permissionId != GovernanceERC20(setup.governanceERC20Base()).MINT_PERMISSION_ID(),
                "must not request mint rights over a token it did not deploy"
            );
        }
    }

    // --- token handling (shared-token support) ---

    function test_prepareInstallationUsesAnIVotesTokenDirectly() public {
        address token = address(new MockVotesErc20());
        (address plugin,) = setup.prepareInstallation(address(dao), _encode(token, true));
        assertEq(
            address(CrispVoting(plugin).getVotingToken()), token, "an IVotes token must be used as-is, not wrapped"
        );
    }

    function test_prepareInstallationWrapsAPlainErc20() public {
        address token = address(new MockPlainErc20());
        (address plugin,) = setup.prepareInstallation(address(dao), _encode(token, true));
        assertTrue(
            address(CrispVoting(plugin).getVotingToken()) != token, "a non-IVotes ERC20 must be wrapped for governance"
        );
    }

    function test_prepareInstallationRevertsWhenTokenIsNotAContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(CrispVotingSetup.TokenNotContract.selector, eoa));
        setup.prepareInstallation(address(dao), _encode(eoa, true));
    }

    // --- symmetry ---

    /// @dev Install and uninstall must be symmetric, or a removed plugin leaves live permissions
    ///      behind. EXECUTE is revoked unconditionally: the uninstall payload cannot know which
    ///      shape was installed, and revoking an unheld permission is a no-op.
    function test_prepareUninstallationRevokesExactlyWhatInstallGranted() public {
        address token = address(new MockVotesErc20());
        (address plugin,) = setup.prepareInstallation(address(dao), _encode(token, true));

        PermissionLib.MultiTargetPermission[] memory revokes = setup.prepareUninstallation(
            address(dao), IPluginSetup.SetupPayload({plugin: plugin, currentHelpers: new address[](0), data: bytes("")})
        );

        for (uint256 i = 0; i < revokes.length; i++) {
            assertEq(
                uint8(revokes[i].operation), uint8(PermissionLib.Operation.Revoke), "uninstall must only ever revoke"
            );
        }

        assertTrue(
            _has(revokes, address(dao), plugin, dao.EXECUTE_PERMISSION_ID()), "EXECUTE on the DAO must be revoked"
        );
        assertTrue(
            _has(revokes, plugin, address(dao), CrispVoting(setup.implementation()).SET_TARGET_CONFIG_PERMISSION_ID()),
            "SET_TARGET_CONFIG must be revoked"
        );
    }
}
