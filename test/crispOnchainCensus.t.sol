// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import {CrispVoting} from "../src/CrispVoting.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {ICRISP} from "../src/ICRISP.sol";
import {IInterfold} from "../src/IInterfold.sol";

/// @dev IVotes-shaped token with configurable `decimals()`.
contract MockDecimalsToken {
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

contract MockInterfoldMinimal {
    function feeToken() external view returns (address) {
        return address(this);
    }

    function activeCryptoConfigId() external pure returns (bytes32) {
        return keccak256("mock-crypto-config");
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MockCensusTimingProgram {
    uint256 public availabilityFinalizationWindow;
}

/// @dev Exposes the encoded request so `customParams` can be decoded and asserted without a live
///      coordinator to issue an e3Id.
contract CrispVotingCensusHarness is CrispVoting {
    function buildRequestParams(uint64 s, uint64 e, uint256 n, uint256 cm, uint256 c)
        external
        view
        returns (IInterfold.E3RequestParams memory)
    {
        return _buildRequestParams(s, e, n, cm, c);
    }

    function voteScale() external view returns (uint256) {
        return _voteScale();
    }
}

/// @notice Pins the census mode and the voting-power floor this plugin requests rounds under.
///
///         The plugin requests ONCHAIN rounds: `CRISPProgram.publishInput` reads each voter's
///         power straight from the token at the round's snapshot, so no census is ever built or
///         published and the coordinator is out of the eligibility path. Silently reverting to
///         TOKEN would put it back in without failing any existing test, which is what this
///         pins.
contract CrispOnchainCensusTest is Test {
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

    function _deploy(address token, uint256 minProposerVotingPower) internal returns (CrispVotingCensusHarness h) {
        h = CrispVotingCensusHarness(
            ProxyLib.deployUUPSProxy(
                address(new CrispVotingCensusHarness()),
                abi.encodeCall(
                    CrispVoting.initialize,
                    ICrispVoting.PluginInitParams({
                        dao: IDAO(address(dao)),
                        token: token,
                        interfold: address(interfold),
                        committeeSize: IInterfold.CommitteeSize(0),
                        paramSet: 0,
                        crispProgramAddress: address(new MockCensusTimingProgram()),
                        computeProviderParams: bytes(""),
                        votingSettings: ICrispVoting.VotingSettings({
                            minProposerVotingPower: minProposerVotingPower, minParticipation: 0, minDuration: 3600
                        })
                    })
                )
            )
        );
    }

    function _decode(IInterfold.E3RequestParams memory p)
        internal
        pure
        returns (uint256 minVotingPower, uint256 censusMode, uint256 divisor)
    {
        (, minVotingPower,,,, censusMode, divisor) =
            abi.decode(p.customParams, (address, uint256, uint256, uint256, uint256, uint256, uint256));
    }

    /// @dev The seven-field tuple `CRISPProgram.validate` decodes. A short encoding reverts there,
    ///      so the field count is as load-bearing as the values.
    function test_requestsAnOnchainCensusRound() public {
        CrispVotingCensusHarness h = _deploy(address(new MockDecimalsToken(18)), 0);
        (, uint256 censusMode,) =
            _decode(h.buildRequestParams(uint64(block.timestamp), uint64(block.timestamp + 3600), 3, 1, 0));

        assertEq(censusMode, uint256(ICRISP.CensusMode.ONCHAIN), "rounds must be requested as ONCHAIN");
        assertTrue(censusMode != uint256(ICRISP.CensusMode.TOKEN), "TOKEN would restore the coordinator's census role");
    }

    /// @dev A zero divisor asks CRISPProgram to derive it from the token's decimals, which is the
    ///      same rule `_voteScale()` applies when reading the tally back.
    function test_divisorIsDerivedFromTheTokenDecimals() public {
        CrispVotingCensusHarness h = _deploy(address(new MockDecimalsToken(18)), 0);
        (,, uint256 divisor) =
            _decode(h.buildRequestParams(uint64(block.timestamp), uint64(block.timestamp + 3600), 3, 1, 0));

        assertEq(divisor, 0, "zero delegates the divisor to CRISPProgram");
    }

    /// @dev The regression this guards. `CRISPProgram.validate` reverts `MinVotingPowerBelowScale`
    ///      when a CUSTOM-credit ONCHAIN round has a floor below the divisor, so a DAO that sets no
    ///      floor at all could not create a single proposal without this clamp.
    function test_zeroFloorIsRaisedToOneBallotUnit() public {
        CrispVotingCensusHarness h = _deploy(address(new MockDecimalsToken(18)), 0);
        (uint256 minVotingPower,,) =
            _decode(h.buildRequestParams(uint64(block.timestamp), uint64(block.timestamp + 3600), 3, 1, 0));

        assertEq(minVotingPower, h.voteScale(), "a zero floor must be raised to one ballot unit");
        assertGt(minVotingPower, 0, "a zero floor would be rejected by CRISPProgram.validate");
    }

    /// @dev The clamp is a floor, not an override: a DAO that deliberately set a high threshold
    ///      must keep it.
    function test_aFloorAboveOneBallotUnitIsPreserved() public {
        uint256 configured = 500e18;
        CrispVotingCensusHarness h = _deploy(address(new MockDecimalsToken(18)), configured);
        (uint256 minVotingPower,,) =
            _decode(h.buildRequestParams(uint64(block.timestamp), uint64(block.timestamp + 3600), 3, 1, 0));

        assertEq(minVotingPower, configured, "a floor above one ballot unit must not be lowered");
    }

    /// @dev Whatever the token's decimals, the requested floor must clear the divisor CRISPProgram
    ///      will derive — that inequality is exactly what `validate` checks.
    function testFuzz_requestedFloorAlwaysClearsTheDerivedDivisor(uint8 decimals, uint256 configuredFloor) public {
        decimals = uint8(bound(uint256(decimals), 0, 30));
        configuredFloor = bound(configuredFloor, 0, type(uint128).max);

        CrispVotingCensusHarness h = _deploy(address(new MockDecimalsToken(decimals)), configuredFloor);
        (uint256 minVotingPower,,) =
            _decode(h.buildRequestParams(uint64(block.timestamp), uint64(block.timestamp + 3600), 3, 1, 0));

        // The divisor CRISPProgram derives for a zero `votingPowerDivisor`.
        uint256 divisor = decimals > 1 ? 10 ** (uint256(decimals) - 1) : 1;

        assertGe(minVotingPower, divisor, "floor must never sit below the divisor");
        assertGe(minVotingPower, configuredFloor, "the clamp must never lower a configured floor");
    }
}
