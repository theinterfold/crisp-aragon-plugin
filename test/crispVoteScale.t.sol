// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import {CrispVoting} from "../src/CrispVoting.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {IInterfold} from "../src/IInterfold.sol";

/// @dev IVotes-shaped token with configurable `decimals()`.
contract MockTokenWithDecimals {
    uint8 private immutable _dec;

    constructor(uint8 d) {
        _dec = d;
    }

    function decimals() external view returns (uint8) {
        return _dec;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

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

/// @dev Bare IVotes token: no `decimals()` at all. `IVotesUpgradeable` does not declare it, and
///      `CrispVotingSetup` accepts such tokens directly, so the plugin must tolerate this.
contract MockTokenNoDecimals {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

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

/// @dev Exposes the internal scale so the cross-boundary rule can be asserted directly.
contract CrispVotingHarness is CrispVoting {
    function voteScale() external view returns (uint256) {
        return _voteScale();
    }
}

/// @notice Pins `_voteScale()` to the CRISP producer's encoding.
///
///         This is a THREE-WAY SYNC between this contract, the CRISP server, and the client SDK.
///         The authority is the SDK's `getScaledBalance`:
///
///             const precision = decimals > 1n ? decimals - 1n : 0n;
///             return balance / 10n ** precision;
///
///         The tally comes back in those units and the quorum check multiplies it back up, so if
///         this drifts from the SDK, quorum silently mis-measures turnout — there is no revert and
///         no visible symptom until a vote fails to reach a quorum it should have reached.
contract CrispVoteScaleTest is Test {
    DAO internal dao;
    MockInterfoldMinimal internal interfold;

    function setUp() public {
        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, (bytes(""), address(this), address(0), ""))
                ))
        );
        interfold = new MockInterfoldMinimal();
    }

    function _deploy(address token) internal returns (CrispVotingHarness h) {
        h = CrispVotingHarness(
            ProxyLib.deployUUPSProxy(
                address(new CrispVotingHarness()),
                abi.encodeCall(
                    CrispVoting.initialize,
                    ICrispVoting.PluginInitParams({
                        dao: IDAO(address(dao)),
                        token: token,
                        interfold: address(interfold),
                        committeeSize: IInterfold.CommitteeSize(0),
                        paramSet: 0,
                        crispProgramAddress: address(0xC0FFEE),
                        computeProviderParams: bytes(""),
                        votingSettings: ICrispVoting.VotingSettings({
                            minProposerVotingPower: 0, minParticipation: 0, minDuration: 3600
                        })
                    })
                )
            )
        );
    }

    /// @dev The SDK's rule, transcribed. Any change here must be a change in the SDK first.
    function _sdkScale(uint8 decimals) internal pure returns (uint256) {
        return decimals > 1 ? 10 ** (uint256(decimals) - 1) : 1;
    }

    function test_voteScaleMatchesTheSdkEncoding() public {
        uint8[5] memory cases = [uint8(2), 6, 8, 18, 24];
        for (uint256 i = 0; i < cases.length; i++) {
            CrispVotingHarness h = _deploy(address(new MockTokenWithDecimals(cases[i])));
            assertEq(h.voteScale(), _sdkScale(cases[i]), "scale must equal 10**(decimals-1)");
        }
    }

    /// @dev The specific regression: 10**(decimals/2) gave 10**9 for an 18-decimal token where the
    ///      producer uses 10**17 — a 10**8 understatement of turnout.
    function test_voteScaleIsNotTheOldHalfDecimalsFormula() public {
        CrispVotingHarness h = _deploy(address(new MockTokenWithDecimals(18)));
        assertEq(h.voteScale(), 1e17, "18-decimal token must scale by 10**17");
        assertTrue(h.voteScale() != 10 ** (uint256(18) / 2), "must not regress to 10**(decimals/2)");
    }

    /// @dev 0/1-decimal tokens are unscaled, matching the SDK's `precision = 0` branch.
    function test_lowDecimalTokensAreUnscaled() public {
        assertEq(_deploy(address(new MockTokenWithDecimals(0))).voteScale(), 1, "0 decimals: unscaled");
        assertEq(_deploy(address(new MockTokenWithDecimals(1))).voteScale(), 1, "1 decimal: unscaled");
    }

    /// @dev A bare IVotes token has no `decimals()`. Reverting here would brick `hasSucceeded`,
    ///      `canExecute` and `execute` for the whole plugin, unrecoverably, after install.
    function test_tokenWithoutDecimalsFallsBackToUnscaledInsteadOfReverting() public {
        assertEq(_deploy(address(new MockTokenNoDecimals())).voteScale(), 1, "missing decimals(): unscaled");
    }

    function testFuzz_voteScaleMatchesTheSdkForAnyRealisticDecimals(uint8 decimals) public {
        // 10**77 is the largest power of ten in uint256, so decimals-1 <= 77.
        decimals = uint8(bound(uint256(decimals), 0, 78));
        CrispVotingHarness h = _deploy(address(new MockTokenWithDecimals(decimals)));
        assertEq(h.voteScale(), _sdkScale(decimals), "scale must track the SDK for any decimals");
    }
}
