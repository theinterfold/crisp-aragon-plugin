// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/* solhint-disable no-console */

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {PluginRepoFactory} from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
import {PluginRepo} from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import {PluginSetupRef} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessorHelpers.sol";
import {GovernanceERC20} from "@aragon/token-voting-plugin/erc20/GovernanceERC20.sol";
import {GovernanceWrappedERC20} from "@aragon/token-voting-plugin/erc20/GovernanceWrappedERC20.sol";

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {CrispVoting} from "../src/CrispVoting.sol";
import {CrispVotingSetup} from "../src/setup/CrispVotingSetup.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {Utils} from "../script/Utils.sol";
import {IDAOFactory} from "../src/IDAOFactory.sol";

contract CrispVotingScript is Script {
    address public pluginRepoFactory;
    IDAOFactory public daoFactory;
    string public nameWithEntropy;
    address[] public pluginAddress;

    function setUp() public {
        pluginRepoFactory = vm.envAddress("PLUGIN_REPO_FACTORY_ADDRESS");
        daoFactory = IDAOFactory(vm.envAddress("DAO_FACTORY_ADDRESS"));
        nameWithEntropy = string.concat("crisp-voting-plugin-", vm.toString(block.timestamp));
    }

    function run() public {
        // 0. Setting up Foundry
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. Deploying the Plugin Setup
        CrispVotingSetup pluginSetup = deployPluginSetup();

        // 2. Publishing it in the Aragon OSx Protocol
        PluginRepo pluginRepo = deployPluginRepo(address(pluginSetup));

        // 3. Defining the DAO Settings
        IDAOFactory.DAOSettings memory daoSettings = getDAOSettings();

        // 4. Defining the plugin settings
        IDAOFactory.PluginSettings[] memory pluginSettings = getPluginSettings(pluginRepo);

        // 5. Deploying the DAO
        vm.recordLogs();
        address createdDAO = daoFactory.createDao(daoSettings, pluginSettings);

        // 6. Getting the Plugin Address
        Vm.Log[] memory logEntries = vm.getRecordedLogs();

        for (uint256 i = 0; i < logEntries.length; i++) {
            if (logEntries[i].topics[0] == keccak256("InstallationApplied(address,address,bytes32,bytes32)")) {
                pluginAddress.push(address(uint160(uint256(logEntries[i].topics[2]))));
            }
        }

        vm.stopBroadcast();

        // 7. Logging the resulting addresses
        console2.log("Plugin Setup: ", address(pluginSetup));
        console2.log("Plugin Repo: ", address(pluginRepo));
        console2.log("Created DAO: ", createdDAO);
        console2.log("Installed Plugins and voting tokens: ");
        for (uint256 i = 0; i < pluginAddress.length; i++) {
            console2.log("- Plugin: ", pluginAddress[i]);
            console2.log("- Token:  ", address(CrispVoting(pluginAddress[i]).getVotingToken()));
        }
    }

    function deployPluginSetup() public returns (CrispVotingSetup) {
        // GovernanceERC20 and GovernanceWrappedERC20 are implementation contracts. If one is
        // required, it will be cloned with token and mint settings from Utils
        GovernanceERC20 governanceERC20Base = new GovernanceERC20(
            IDAO(address(0)),
            "",
            "",
            GovernanceERC20.MintSettings({receivers: new address[](0), amounts: new uint256[](0)})
        );
        GovernanceWrappedERC20 governanceWrappedERC20Base =
            new GovernanceWrappedERC20(IERC20Upgradeable(address(0)), "", "");
        address crispVoting = address(new CrispVoting());
        CrispVotingSetup pluginSetup =
            new CrispVotingSetup(governanceERC20Base, governanceWrappedERC20Base, crispVoting);
        return pluginSetup;
    }

    function deployPluginRepo(address pluginSetup) public returns (PluginRepo pluginRepo) {
        pluginRepo = PluginRepoFactory(pluginRepoFactory)
            .createPluginRepoWithFirstVersion(
                nameWithEntropy,
                pluginSetup,
                msg.sender,
                "1", // TODO: Give these actual values on prod
                "1"
            );
    }

    function getDAOSettings() public view returns (IDAOFactory.DAOSettings memory) {
        return IDAOFactory.DAOSettings(address(0), "", nameWithEntropy, "");
    }

    function getCrispVotingSetupParams()
        internal
        returns (
            ICrispVoting.PluginInitParams memory params,
            CrispVotingSetup.TokenSettings memory tokenSettings,
            GovernanceERC20.MintSettings memory mintSettings
        )
    {
        (, tokenSettings, mintSettings) = Utils.getGovernanceTokenAndMintSettings();
        Utils.CrispEnvVariables memory crispEnvVariables = Utils.readCrispEnv();

        /// @notice dao and token get set in prepare installation
        params = ICrispVoting.PluginInitParams({
            dao: IDAO(address(0)),
            token: address(0),
            interfold: crispEnvVariables.interfold,
            committeeSize: crispEnvVariables.committeeSize,
            paramSet: crispEnvVariables.paramSet,
            crispProgramAddress: crispEnvVariables.crispProgramAddress,
            computeProviderParams: crispEnvVariables.computeProviderParams,
            votingSettings: crispEnvVariables.votingSettings
        });
    }

    function getPluginSettings(PluginRepo pluginRepo)
        public
        returns (IDAOFactory.PluginSettings[] memory pluginSettings)
    {
        (
            ICrispVoting.PluginInitParams memory params,
            CrispVotingSetup.TokenSettings memory tokenSettings,
            GovernanceERC20.MintSettings memory mintSettings
        ) = getCrispVotingSetupParams();
        bytes memory pluginSettingsData = abi.encode(params, tokenSettings, mintSettings);
        PluginRepo.Tag memory tag = PluginRepo.Tag(1, 1);
        pluginSettings = new IDAOFactory.PluginSettings[](1);
        pluginSettings[0] = IDAOFactory.PluginSettings(PluginSetupRef(tag, pluginRepo), pluginSettingsData);
    }
}
