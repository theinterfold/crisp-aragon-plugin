// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {TestBase} from "./lib/TestBase.sol";

import {Action} from "@aragon/osx/core/dao/DAO.sol";
import {SimpleBuilder} from "./builders/SimpleBuilder.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {CrispVoting} from "../src/CrispVoting.sol";
import {console} from "forge-std/console.sol";
import {IInterfold} from "../src/IInterfold.sol";

contract MyPluginTest is TestBase {
    DAO dao;
    CrispVoting plugin;

    /// @notice these are the addresses when deploying on a local hardhat network
    address crispProgramAddress = 0x67d269191c92Caf3cD7723F116c85e6E9bf55933;
    address interfoldAddress = 0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0;

    bytes computeProviderParams =
        "0x7b226e616d65223a225249534330222c22706172616c6c656c223a66616c73652c2262617463685f73697a65223a347d";

    ICrispVoting.PluginInitParams pluginInitParams = ICrispVoting.PluginInitParams({
        dao: dao,
        token: address(0),
        interfold: interfoldAddress,
        committeeSize: IInterfold.CommitteeSize(0),
        crispProgramAddress: crispProgramAddress,
        paramSet: 0,
        computeProviderParams: computeProviderParams,
        votingSettings: ICrispVoting.VotingSettings({minProposerVotingPower: 0, minParticipation: 0, minDuration: 0})
    });

    function setUp() public {
        // Customize the Builder to feature more default values and overrides
        (dao, plugin) = new SimpleBuilder().build();
    }

    function test_RevertWhen_CallingInitialize() external {
        // It Should revert
        vm.expectRevert("Initializable: contract is already initialized");
        plugin.initialize(pluginInitParams);
    }

    function test_WhenCallingDao() external view {
        // It Should return the right values
        assertEq(address(plugin.dao()), address(dao));
    }
}
