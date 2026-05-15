// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ValidatorManager} from "../src/core/ValidatorManager.sol";
import {ICorpActionTypes} from "../src/interfaces/ICorpActionTypes.sol";

contract ConfigureValidators is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address validatorManagerAddr = vm.envAddress("VALIDATOR_MANAGER");

        vm.startBroadcast(deployerKey);

        ValidatorManager vm_ = ValidatorManager(validatorManagerAddr);

        // Configure quorums per severity
        // Low severity: 2-of-3
        vm_.setQuorum(ICorpActionTypes.ActionType.TICKER_CHANGE, 2);

        // Medium severity: 3-of-5
        vm_.setQuorum(ICorpActionTypes.ActionType.DIVIDEND, 3);
        vm_.setQuorum(ICorpActionTypes.ActionType.FORWARD_SPLIT, 3);
        vm_.setQuorum(ICorpActionTypes.ActionType.REVERSE_SPLIT, 3);

        // High severity: 4-of-5
        vm_.setQuorum(ICorpActionTypes.ActionType.MERGER_CASH, 4);
        vm_.setQuorum(ICorpActionTypes.ActionType.MERGER_STOCK, 4);
        vm_.setQuorum(ICorpActionTypes.ActionType.MERGER_HYBRID, 4);
        vm_.setQuorum(ICorpActionTypes.ActionType.SPINOFF, 4);
        vm_.setQuorum(ICorpActionTypes.ActionType.DELISTING, 4);
        vm_.setQuorum(ICorpActionTypes.ActionType.LIQUIDATION, 4);

        // Super majority for emergency resume: 4-of-5
        vm_.setSuperMajority(4);

        vm.stopBroadcast();

        console2.log("Validators configured");
    }
}
