// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import {CrispVoting} from "../src/CrispVoting.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {IInterfold} from "../src/IInterfold.sol";

contract MockTokenQuorum {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1000e18;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 1000e18;
    }

    function getVotes(address) external pure returns (uint256) {
        return 1000e18;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 1000e18;
    }
}

contract CrispVotingHarnessQuorum is CrispVoting {
    function canExecuteWithCounts(uint256 _proposalId, uint256[] memory counts) external view returns (bool) {
        return _canExecute(_proposalId, counts);
    }

    function setProposalForTesting(uint256 _proposalId, uint32 minPart) external {
        Proposal storage p = proposals[_proposalId];
        p.parameters.snapshotBlock = 100;
        p.parameters.numOptions = 2;
        p.parameters.minParticipation = minPart;
    }
}

/// @notice Asserts that CrispVoting uses the snapshotted proposal.parameters.minParticipation
///         rather than dynamic votingSettings.minParticipation during quorum checks.
contract CrispQuorumSnapshottedTest is Test {
    DAO internal dao;
    CrispVotingHarnessQuorum internal harness;
    MockTokenQuorum internal token;

    function setUp() public {
        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                address(new DAO()), abi.encodeCall(DAO.initialize, (bytes(""), address(this), address(0), ""))
            ))
        );
        token = new MockTokenQuorum();
        harness = CrispVotingHarnessQuorum(
            ProxyLib.deployUUPSProxy(
                address(new CrispVotingHarnessQuorum()),
                abi.encodeCall(
                    CrispVoting.initialize,
                    ICrispVoting.PluginInitParams({
                        dao: IDAO(address(dao)),
                        token: address(token),
                        interfold: address(0x111),
                        committeeSize: IInterfold.CommitteeSize(0),
                        paramSet: 0,
                        crispProgramAddress: address(0xC0FFEE),
                        computeProviderParams: bytes(""),
                        votingSettings: ICrispVoting.VotingSettings({
                            minProposerVotingPower: 0, minParticipation: 10, minDuration: 3600
                        })
                    })
                )
            )
        );
    }

    function test_quorumUsesSnapshottedMinParticipation() public {
        // Create dummy proposal #1 with snapshotted minParticipation = 10%
        harness.setProposalForTesting(1, 10);

        // 150 votes out of 1000 total supply = 15% turnout (>= 10% quorum)
        uint256[] memory counts = new uint256[](2);
        counts[0] = 100; // yes
        counts[1] = 50;  // no

        assertTrue(harness.canExecuteWithCounts(1, counts), "Proposal #1 should pass 10% quorum");

        // Now DAO updates global votingSettings minParticipation to 50%
        harness.updateVotingSettings(
            ICrispVoting.VotingSettings({
                minProposerVotingPower: 0, minParticipation: 50, minDuration: 3600
            })
        );

        // Proposal #1 was created when minParticipation was 10%, so it must STILL pass quorum
        assertTrue(
            harness.canExecuteWithCounts(1, counts),
            "Proposal #1 must respect snapshotted 10% minParticipation, not updated 50% setting"
        );
    }
}
