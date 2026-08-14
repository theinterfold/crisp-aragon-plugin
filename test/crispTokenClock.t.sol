// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import {CrispVoting} from "../src/CrispVoting.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {IInterfold} from "../src/IInterfold.sol";

/// @dev IVotes token on the OZ default clock: checkpoints are keyed by block number.
contract MockBlockClockToken {
    function clock() external view returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Mirrors OZ: a timepoint at or after `clock()` is a future lookup and reverts;
    ///      anything before the first checkpoint reads as zero rather than reverting.
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        require(timepoint < block.number, "future lookup");
        return 1_000e18;
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256 timepoint) external view returns (uint256) {
        require(timepoint < block.number, "future lookup");
        return 100e18;
    }
}

/// @dev IVotes token with `CLOCK_MODE=timestamp` (OZ `VotesTimestamp`). This is the shape the
///      deployed governance token actually has, and the one the old `block.number - 1` snapshot
///      silently broke: a block number is far below any real timestamp, so it is a valid *past*
///      lookup that returns zero instead of reverting.
contract MockTimestampClockToken {
    /// @dev First checkpoint. Reads before this are genuinely zero.
    uint256 public immutable deployedAt;

    constructor() {
        deployedAt = block.timestamp;
    }

    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        require(timepoint < block.timestamp, "future lookup");
        return timepoint < deployedAt ? 0 : 1_000e18;
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256 timepoint) external view returns (uint256) {
        require(timepoint < block.timestamp, "future lookup");
        return timepoint < deployedAt ? 0 : 100e18;
    }
}

/// @dev Predates ERC-6372: no `clock()`. `IVotesUpgradeable` does not declare one and
///      `CrispVotingSetup` accepts such tokens, so the plugin must not revert on them.
contract MockNoClockToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 1_000e18;
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 100e18;
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

/// @dev Exposes the internal clock so the snapshot units can be asserted without creating a
///      proposal (which would need a live Interfold to issue an e3Id).
contract CrispVotingClockHarness is CrispVoting {
    function tokenClock() external view returns (uint256) {
        return _tokenClock();
    }
}

/// @notice Pins `snapshotBlock` to the voting token's ERC-6372 clock.
///
///         `snapshotBlock` is passed straight to `getPastVotes` / `getPastTotalSupply`, so it has
///         to be in the units the token keeps its checkpoints in. The failure mode when it is not
///         is uniquely nasty: against a `CLOCK_MODE=timestamp` token a block number is a valid
///         *past* timepoint, so nothing reverts — every holder just reads as having zero voting
///         power, the census looks empty, and `_canExecute` bails on `_totalVotingPower == 0`,
///         making every proposal permanently unexecutable.
contract CrispTokenClockTest is Test {
    DAO internal dao;
    MockInterfoldMinimal internal interfold;

    function setUp() public {
        // Push both clocks well clear of zero so a block number and a timestamp cannot coincide.
        vm.roll(11_500_000);
        vm.warp(1_786_700_000);

        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(new DAO()), abi.encodeCall(DAO.initialize, (bytes(""), address(this), address(0), ""))
                ))
        );
        interfold = new MockInterfoldMinimal();
    }

    function _deploy(address token) internal returns (CrispVotingClockHarness h) {
        h = CrispVotingClockHarness(
            ProxyLib.deployUUPSProxy(
                address(new CrispVotingClockHarness()),
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

    function test_timestampClockedTokenSnapshotsInTimestamps() public {
        CrispVotingClockHarness h = _deploy(address(new MockTimestampClockToken()));
        assertEq(h.tokenClock(), block.timestamp, "must follow the token's timestamp clock");
        assertTrue(h.tokenClock() != block.number, "must not fall back to the block number");
    }

    function test_blockClockedTokenSnapshotsInBlockNumbers() public {
        CrispVotingClockHarness h = _deploy(address(new MockBlockClockToken()));
        assertEq(h.tokenClock(), block.number, "must follow the token's block-number clock");
    }

    /// @dev A bare IVotes token has no `clock()`; `block.number` is what OZ's own default returns.
    function test_tokenWithoutClockFallsBackToBlockNumberInsteadOfReverting() public {
        CrispVotingClockHarness h = _deploy(address(new MockNoClockToken()));
        assertEq(h.tokenClock(), block.number, "missing clock(): fall back to block.number");
    }

    /// @dev The regression itself. `snapshotBlock = block.number - 1` against a timestamp-clocked
    ///      token does not revert — it reads zero, which is why this shipped unnoticed.
    function test_blockNumberSnapshotSilentlyReadsZeroOnATimestampClockedToken() public {
        MockTimestampClockToken token = new MockTimestampClockToken();
        // Move past the mock's first checkpoint so a correctly-derived snapshot reads non-zero;
        // otherwise both branches read zero and the test proves nothing.
        vm.warp(block.timestamp + 1);

        assertEq(token.getPastVotes(address(this), block.number - 1), 0, "block number reads as no voting power");
        assertEq(token.getPastTotalSupply(block.number - 1), 0, "block number reads as no total supply");

        CrispVotingClockHarness h = _deploy(address(token));
        uint256 snapshot = h.tokenClock() - 1;

        assertEq(token.getPastVotes(address(this), snapshot), 100e18, "clock-derived snapshot reads real power");
        assertEq(token.getPastTotalSupply(snapshot), 1_000e18, "clock-derived snapshot reads real supply");
    }

    /// @dev `_tokenClock() - 1` must always be a readable past timepoint, never a future lookup.
    function testFuzz_snapshotIsAlwaysAReadablePastTimepoint(uint32 blocksAhead, uint32 secondsAhead) public {
        vm.roll(block.number + bound(uint256(blocksAhead), 1, 1_000_000));
        vm.warp(block.timestamp + bound(uint256(secondsAhead), 1, 1_000_000));

        MockTimestampClockToken tsToken = new MockTimestampClockToken();
        MockBlockClockToken blockToken = new MockBlockClockToken();

        // Move past the mock's own first checkpoint so a correct read is non-zero.
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        uint256 tsSnapshot = _deploy(address(tsToken)).tokenClock() - 1;
        assertEq(tsToken.getPastVotes(address(this), tsSnapshot), 100e18, "timestamp snapshot must be readable");

        uint256 blockSnapshot = _deploy(address(blockToken)).tokenClock() - 1;
        assertEq(blockToken.getPastVotes(address(this), blockSnapshot), 100e18, "block snapshot must be readable");
    }
}
