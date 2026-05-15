// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ActionRegistry} from "../src/core/ActionRegistry.sol";
import {ICorpActionTypes} from "../src/interfaces/ICorpActionTypes.sol";

contract RegisterExecutors is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address registryAddr = vm.envAddress("REGISTRY_ADDRESS");
        address dividendAddr = vm.envAddress("DIVIDEND_DISTRIBUTOR");
        address splitAddr = vm.envAddress("SPLIT_EXECUTOR");
        address mergerAddr = vm.envAddress("MERGER_HANDLER");
        address spinoffAddr = vm.envAddress("SPINOFF_EXECUTOR");
        address delistingAddr = vm.envAddress("DELISTING_MANAGER");
        address tickerAddr = vm.envAddress("TICKER_MIGRATOR");

        vm.startBroadcast(deployerKey);

        ActionRegistry registry = ActionRegistry(registryAddr);

        registry.registerExecutor(ICorpActionTypes.ActionType.DIVIDEND, dividendAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.FORWARD_SPLIT, splitAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.REVERSE_SPLIT, splitAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.MERGER_CASH, mergerAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.MERGER_STOCK, mergerAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.MERGER_HYBRID, mergerAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.SPINOFF, spinoffAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.DELISTING, delistingAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.LIQUIDATION, delistingAddr);
        registry.registerExecutor(ICorpActionTypes.ActionType.TICKER_CHANGE, tickerAddr);

        vm.stopBroadcast();

        console2.log("All executors registered");
    }
}
