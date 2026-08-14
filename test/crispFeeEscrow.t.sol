// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import {CrispVoting} from "../src/CrispVoting.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {IInterfold} from "../src/IInterfold.sol";
import {E3} from "../src/IE3.sol";
import {IStagedProposalProcessor} from "../src/IStagedProposalProcessor.sol";

// --- Mocks -----------------------------------------------------------------

contract MockFeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockVotesToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) private _votes;

    function setVotes(address who, uint256 v) external {
        _votes[who] = v;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function getVotes(address who) external view returns (uint256) {
        return _votes[who];
    }

    function getPastVotes(address who, uint256) external view returns (uint256) {
        return _votes[who];
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 1_000e18;
    }
}

contract MockInterfold {
    address public feeTokenAddr;
    uint256 public quote = 10e6;

    constructor(address _feeToken) {
        feeTokenAddr = _feeToken;
    }

    function feeToken() external view returns (address) {
        return feeTokenAddr;
    }

    /// @dev Priced off the request so a quote that was built from different parameters than the
    /// request produces a different number. A flat price would let `quoteFee` and `createProposal`
    /// disagree about the window or the ballot and still look identical in tests.
    function _price(IInterfold.E3RequestParams calldata p) internal view returns (uint256) {
        return quote + (p.inputWindow[1] - p.inputWindow[0]) + p.customParams.length;
    }

    function getE3Quote(IInterfold.E3RequestParams calldata p) external view returns (uint256) {
        return _price(p);
    }

    /// @dev Must match IInterfold.request exactly — it returns (uint256, E3), not (uint256, bytes).
    function request(IInterfold.E3RequestParams calldata p) external returns (uint256, E3 memory e3) {
        MockFeeToken(feeTokenAddr).transferFrom(msg.sender, address(this), _price(p));
        return (1, e3);
    }
}

/// @dev Stands in for Aragon's SPP: reports a creator for a parent proposal id.
contract MockSpp {
    mapping(uint256 => address) public creators;

    function setCreator(uint256 id, address who) external {
        creators[id] = who;
    }

    function getProposal(uint256 id) external view returns (IStagedProposalProcessor.Proposal memory p) {
        p.creator = creators[id];
    }

    /// @dev Calls the plugin exactly as the SPP does: the SPP is `msg.sender`, and the metadata
    ///      is its own attestation `(spp, sppProposalId, stageId)`.
    function createOn(address plugin, uint256 sppProposalId, uint64 start, uint64 end, bytes calldata data)
        external
        returns (uint256)
    {
        bytes memory metadata = abi.encode(address(this), sppProposalId, uint16(0));
        return CrispVoting(plugin).createProposal(metadata, new Action[](0), start, end, data);
    }
}

// --- Tests -----------------------------------------------------------------

/// @notice Covers the fee escrow, and specifically the reason it exists: under the SPP the CALLER
///         is the SPP contract, which holds no fee tokens. Pulling the fee from `msg.sender` (the
///         previous behaviour) makes every staged proposal revert, so the fee is instead debited
///         from the escrowed credit of the account the SPP names as the parent proposal's creator.
contract CrispFeeEscrowTest is Test {
    DAO internal dao;
    MockFeeToken internal feeToken;
    MockVotesToken internal votingToken;
    MockInterfold internal interfold;
    CrispVoting internal plugin;
    MockSpp internal spp;

    address internal alice = address(0xA11CE);
    address internal mallory = address(0x4A110);

    function setUp() public {
        // `createProposal` stores `snapshotBlock: block.number - 1`, which underflows at block 0,
        // and the date validation needs a non-zero timestamp.
        vm.roll(100);
        vm.warp(1_000_000);

        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, (bytes(""), address(this), address(0), ""))
                ))
        );

        feeToken = new MockFeeToken();
        votingToken = new MockVotesToken();
        interfold = new MockInterfold(address(feeToken));
        spp = new MockSpp();

        plugin = CrispVoting(
            ProxyLib.deployUUPSProxy(
                address(new CrispVoting()),
                abi.encodeCall(
                    CrispVoting.initialize,
                    ICrispVoting.PluginInitParams({
                        dao: IDAO(address(dao)),
                        token: address(votingToken),
                        interfold: address(interfold),
                        committeeSize: IInterfold.CommitteeSize(0),
                        paramSet: 0,
                        crispProgramAddress: address(0xC0FFEE),
                        computeProviderParams: bytes(""),
                        votingSettings: ICrispVoting.VotingSettings({
                            minProposerVotingPower: 1, minParticipation: 0, minDuration: 60
                        })
                    })
                )
            )
        );
    }

    function _fund(address who, uint256 amount) internal {
        feeToken.mint(who, amount);
        vm.startPrank(who);
        feeToken.approve(address(plugin), amount);
        plugin.deposit(amount);
        vm.stopPrank();
    }

    function _data() internal pure returns (bytes memory) {
        // (allowFailureMap, numOptions, creditMode, credits)
        return abi.encode(uint256(0), uint256(3), uint256(1), uint256(0));
    }

    function _start() internal view returns (uint64) {
        return uint64(block.timestamp) + 1;
    }

    function _end() internal view returns (uint64) {
        return uint64(block.timestamp) + 3600;
    }

    /// @dev The fee these tests expect to be charged. Asserting against `quoteFee` rather than a
    /// literal is the point: if the quote were built from different parameters than the request,
    /// the priced mock would return a different number and every expectation below would break.
    function _quote() internal view returns (uint256) {
        return plugin.quoteFee(_start(), _end(), _data());
    }

    // --- escrow basics ---

    function test_depositAndWithdraw() public {
        feeToken.mint(alice, 100e6);
        vm.startPrank(alice);
        feeToken.approve(address(plugin), 100e6);
        plugin.deposit(100e6);
        assertEq(plugin.feeCredits(alice), 100e6, "deposit credits the payer");

        plugin.withdraw(40e6);
        assertEq(plugin.feeCredits(alice), 60e6, "withdraw debits the payer");
        assertEq(feeToken.balanceOf(alice), 40e6, "withdraw returns the tokens");
        vm.stopPrank();
    }

    function test_withdrawCannotExceedCredit() public {
        _fund(alice, 10e6);
        vm.prank(alice);
        vm.expectRevert();
        plugin.withdraw(11e6);
    }

    // --- the reason the escrow exists ---

    /// @dev THE staged-shape test. The SPP is `msg.sender` and holds no fee tokens; the fee must
    ///      come from the parent proposal creator's escrow instead.
    function test_sppProposalChargesTheParentCreatorNotTheCallingSpp() public {
        _fund(alice, 50e6);
        spp.setCreator(7, alice);
        votingToken.setVotes(address(spp), 0); // the SPP has no voting power, and needs none

        uint256 fee = _quote();

        vm.prank(address(spp));
        spp.createOn(address(plugin), 7, _start(), _end(), _data());

        assertEq(plugin.feeCredits(alice), 50e6 - fee, "the parent creator's credit paid the fee");
        assertEq(feeToken.balanceOf(address(spp)), 0, "the SPP never needed tokens");
    }

    /// @dev Without escrow this reverted, because the SPP holds nothing to transferFrom.
    function test_sppProposalRevertsWhenTheCreatorHasNoCredit() public {
        spp.setCreator(7, alice); // alice never deposited

        vm.expectRevert(abi.encodeWithSelector(ICrispVoting.InsufficientFeeCredit.selector, alice, _quote(), 0));
        spp.createOn(address(plugin), 7, _start(), _end(), _data());
    }

    // --- the attack the attestation prevents ---

    /// @dev A direct caller must not be able to hand-craft 96-byte metadata naming someone else's
    ///      SPP proposal and spend THEIR escrow. The staged path only applies when the caller IS
    ///      the SPP it names; otherwise it falls through to the direct path and charges the caller.
    function test_cannotForgeSppMetadataToSpendAnotherAccountsCredit() public {
        _fund(alice, 50e6);
        spp.setCreator(7, alice);
        votingToken.setVotes(mallory, 1); // mallory is an eligible proposer, but has no credit

        // Mallory calls directly, pretending to be a sub-proposal of alice's SPP proposal.
        bytes memory forged = abi.encode(address(spp), uint256(7), uint16(0));

        // Read the quote BEFORE the prank: `vm.prank` applies to the next call, and a `quoteFee`
        // in the expectRevert arguments would swallow it.
        uint256 fee = _quote();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(ICrispVoting.InsufficientFeeCredit.selector, mallory, fee, 0));
        plugin.createProposal(forged, new Action[](0), _start(), _end(), _data());

        assertEq(plugin.feeCredits(alice), 50e6, "alice's credit must be untouched");
    }

    // --- direct shape still works ---

    function test_directProposalChargesTheCallerAndKeepsEligibility() public {
        _fund(alice, 50e6);
        votingToken.setVotes(alice, 1);

        uint256 fee = _quote();

        vm.prank(alice);
        plugin.createProposal(bytes("ipfs://x"), new Action[](0), _start(), _end(), _data());

        assertEq(plugin.feeCredits(alice), 50e6 - fee, "the direct caller pays from their own escrow");
    }

    function test_directProposalStillEnforcesProposerVotingPower() public {
        _fund(mallory, 50e6);
        votingToken.setVotes(mallory, 0);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(ICrispVoting.ProposalCreationForbidden.selector, mallory));
        plugin.createProposal(bytes("ipfs://x"), new Action[](0), _start(), _end(), _data());
    }
}
