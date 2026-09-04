// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

import {Utils} from "../script/Utils.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {IInterfold} from "../src/IInterfold.sol";

contract UtilsHarness {
    function validate(uint256 chainId, Utils.CrispEnvVariables memory config) external pure {
        Utils.validateDeploymentPolicy(chainId, config);
    }
}

contract UtilsTest is Test {
    UtilsHarness internal harness = new UtilsHarness();

    function _config() internal pure returns (Utils.CrispEnvVariables memory config) {
        config.paramSet = 1;
        config.committeeSize = IInterfold.CommitteeSize.Small;
        config.votingSettings = ICrispVoting.VotingSettings({
            minProposerVotingPower: 12_000 ether, minParticipation: 2, minDuration: 5 days
        });
    }

    function test_mainnetAcceptsTheLaunchPolicy() external view {
        harness.validate(1, _config());
    }

    function test_nonMainnetAllowsTestSettings() external view {
        Utils.CrispEnvVariables memory config;
        harness.validate(11_155_111, config);
    }

    function test_mainnetRejectsInsecureParams() external {
        Utils.CrispEnvVariables memory config = _config();
        config.paramSet = 0;
        vm.expectRevert(abi.encodeWithSelector(Utils.MainnetRequiresSecureParams.selector, uint8(0)));
        harness.validate(1, config);
    }

    function test_mainnetRejectsTheWrongCommittee() external {
        Utils.CrispEnvVariables memory config = _config();
        config.committeeSize = IInterfold.CommitteeSize.Minimum;
        vm.expectRevert(
            abi.encodeWithSelector(Utils.MainnetRequiresSmallCommittee.selector, IInterfold.CommitteeSize.Minimum)
        );
        harness.validate(1, config);
    }

    function test_mainnetRejectsAShortProposal() external {
        Utils.CrispEnvVariables memory config = _config();
        config.votingSettings.minDuration = 5 days - 1;
        vm.expectRevert(
            abi.encodeWithSelector(Utils.MainnetDurationTooShort.selector, uint64(5 days - 1), uint64(5 days))
        );
        harness.validate(1, config);
    }
}
