// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  02_ExecuteAfterTimelock
 * @notice Step 2 of the P0 lifecycle demo.
 *
 *   - Reads the intentId from the INTENT_ID env var (output of Step 1)
 *   - Verifies the timelock has elapsed
 *   - Calls registry.executeAction(intentId)
 *   - Logs the resulting state
 *
 * Usage:
 *   INTENT_ID=0x... forge script script/demo/02_ExecuteAfterTimelock.s.sol \
 *       --rpc-url $RPC_URL --broadcast -vvvv
 */

import {Script, console2} from "forge-std/Script.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";

contract ExecuteAfterTimelock is Script, ICorpActionTypes {
    address constant REGISTRY_ADDR = 0x1D3c8f75A0822c56FC1d7DDd41106a469f3E1A35;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        bytes32 intentId    = vm.envBytes32("INTENT_ID");

        console2.log("============================================");
        console2.log(" Step 2: Execute After Timelock");
        console2.log("============================================");
        console2.log("Executor:", deployer);
        console2.log("Intent ID:");
        console2.logBytes32(intentId);

        ActionRegistry registry = ActionRegistry(REGISTRY_ADDR);

        // ------------------------------------------------------------------
        // 1. Check current state
        // ------------------------------------------------------------------
        console2.log("\n--- 1. Pre-flight checks ---");

        ActionIntent memory intent = registry.getAction(intentId);
        console2.log("Current state:", uint256(intent.state));
        console2.log("  (3 = QUEUED, required for execution)");

        require(
            intent.state == ActionState.QUEUED,
            "Action is not in QUEUED state"
        );

        // ------------------------------------------------------------------
        // 2. Check timelock
        // ------------------------------------------------------------------
        console2.log("\n--- 2. Timelock check ---");

        uint256 executionTime = registry.getExecutionTime(intentId);
        console2.log("Execution time :", executionTime);
        console2.log("Current time   :", block.timestamp);

        if (block.timestamp < executionTime) {
            uint256 remaining = executionTime - block.timestamp;
            console2.log("Timelock NOT expired. Remaining seconds:", remaining);
            console2.log("");
            console2.log("Wait and re-run, or use vm.warp in a local fork:");
            console2.log("  vm.warp(executionTime + 1)");
            revert("Timelock has not elapsed yet");
        }

        console2.log("Timelock elapsed -- ready to execute");

        // ------------------------------------------------------------------
        // 3. Execute the action
        // ------------------------------------------------------------------
        console2.log("\n--- 3. Executing action ---");

        vm.startBroadcast(deployerKey);
        registry.executeAction(intentId);
        vm.stopBroadcast();

        console2.log("executeAction() called successfully");

        // ------------------------------------------------------------------
        // 4. Verify post-execution state
        // ------------------------------------------------------------------
        console2.log("\n--- 4. Post-execution verification ---");

        ActionIntent memory executed = registry.getAction(intentId);
        console2.log("New state:", uint256(executed.state));
        console2.log("  (4 = EXECUTED, 5 = FAILED)");
        console2.log("Executed at:", executed.executedAt);

        if (executed.state == ActionState.EXECUTED) {
            console2.log("");
            console2.log("SUCCESS -- Dividend distribution is now active.");
            console2.log("Holders can claim via 03_ClaimDividend.s.sol");
        } else if (executed.state == ActionState.FAILED) {
            console2.log("");
            console2.log("FAILED -- Check executor logs for details.");
        }

        console2.log("\n============================================");
    }
}
