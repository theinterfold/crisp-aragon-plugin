// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Test.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";

import {GovernanceERC20} from "@aragon/token-voting-plugin/erc20/GovernanceERC20.sol";

import {ICrispVoting} from "../src/ICrispVoting.sol";
import {IInterfold} from "../src/IInterfold.sol";
import {CrispVotingSetup} from "../src/setup/CrispVotingSetup.sol";

library Utils {
    // the canonical hevm cheat‑code address
    Vm public constant VM = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));

    struct CrispEnvVariables {
        address interfold;
        address crispProgramAddress;
        ICrispVoting.VotingSettings votingSettings;
        IPlugin.TargetConfig targetConfig;
        IInterfold.CommitteeSize committeeSize;
        uint8 paramSet;
        bytes computeProviderParams;
    }

    function readCrispEnv() public view returns (CrispEnvVariables memory crispEnvVariables) {
        IPlugin.TargetConfig memory defaultTargetConfig =
            IPlugin.TargetConfig({target: address(0), operation: IPlugin.Operation.Call});

        crispEnvVariables.interfold = VM.envAddress("INTERFOLD_ADDRESS");
        crispEnvVariables.crispProgramAddress = VM.envAddress("CRISP_PROGRAM_ADDRESS");
        crispEnvVariables.votingSettings = ICrispVoting.VotingSettings({
            minProposerVotingPower: VM.envUint("MINIMUM_PROPOSER_VOTING_POWER"),
            minDuration: uint64(VM.envUint("MINIMUM_DURATION")),
            minParticipation: uint32(VM.envUint("MINIMUM_PARTICIPATION"))
        });
        crispEnvVariables.targetConfig = defaultTargetConfig;
        crispEnvVariables.committeeSize = IInterfold.CommitteeSize(uint8(VM.envUint("COMMITTEE_SIZE")));
        crispEnvVariables.computeProviderParams = VM.envBytes("COMPUTE_PROVIDER_PARAMS");
        crispEnvVariables.paramSet = uint8(VM.envUint("PARAM_SET"));
    }

    function getGovernanceTokenAndMintSettings()
        public
        returns (GovernanceERC20, CrispVotingSetup.TokenSettings memory, GovernanceERC20.MintSettings memory)
    {
        // TOKEN_ADDRESS selects the governance token:
        //   unset / 0x0  -> a fresh `GovernanceERC20` is deployed and minted per MINT_SETTINGS_*
        //   an address   -> that token is used. If it already implements IVotes it is used
        //                   directly; otherwise the setup wraps it in a GovernanceWrappedERC20.
        // Reusing an existing token is what lets several plugins (e.g. a public and a private
        // process) share one token, so voting power and delegation are identical across them.
        CrispVotingSetup.TokenSettings memory tokenSettings = CrispVotingSetup.TokenSettings({
            addr: VM.envOr("TOKEN_ADDRESS", address(0)),
            name: VM.envString("TOKEN_NAME"),
            symbol: VM.envString("TOKEN_SYMBOL")
        });
        GovernanceERC20.MintSettings memory mintSettings;

        // Optional: only consulted when a fresh token is deployed above. An existing-token
        // install mints nothing, so requiring these would block that path for no reason.
        address[] memory receivers = VM.envOr("MINT_SETTINGS_RECEIVERS", ",", new address[](0));
        uint256 amount = VM.envOr("MINT_SETTINGS_AMOUNT", uint256(0));
        mintSettings.receivers = receivers;
        mintSettings.amounts = new uint256[](receivers.length);
        for (uint256 i = 0; i < receivers.length; i++) {
            mintSettings.amounts[i] = amount;
        }

        GovernanceERC20 governanceERC20Base =
            new GovernanceERC20(IDAO(address(0x0)), tokenSettings.name, tokenSettings.symbol, mintSettings);
        return (governanceERC20Base, tokenSettings, mintSettings);
    }
}
