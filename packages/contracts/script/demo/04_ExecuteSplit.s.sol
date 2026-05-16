// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  04_ExecuteSplit
 * @notice Step 4 of the P0 lifecycle demo -- NVDA 10:1 Forward Split.
 *
 *   - Deploys a MockERC8056 for NVDA
 *   - Proposes a 10:1 forward split ActionIntent
 *   - Validates, queues, and executes (uses vm.warp for local demo)
 *   - Verifies the uiMultiplier changed from 1e18 to 10e18
 *
 * Usage:
 *   forge script script/demo/04_ExecuteSplit.s.sol \
 *       --rpc-url $RPC_URL --broadcast -vvvv
 */

import {Script, console2} from "forge-std/Script.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {ValidatorManager} from "../../src/core/ValidatorManager.sol";
import {SplitExecutor} from "../../src/executors/SplitExecutor.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {MockERC8056} from "../../test/mocks/MockERC8056.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ExecuteSplit is Script, ICorpActionTypes {
    // ---- Deployed addresses (Robinhood Chain Testnet) ----
    address constant REGISTRY_ADDR   = 0x1D3c8f75A0822c56FC1d7DDd41106a469f3E1A35;
    address constant VALIDATOR_MGR   = 0xE3fe1728B0Ff8811d1f65Edfe3C9bb58B0a88473;
    address constant SPLIT_EXEC_ADDR = 0x710a6aCf4C11eD4E80baCE15C50193328A3c73E4;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("============================================");
        console2.log(" Step 4: NVDA 10:1 Forward Split");
        console2.log("============================================");
        console2.log("Deployer / Validator:", deployer);

        vm.startBroadcast(deployerKey);

        // ------------------------------------------------------------------
        // 1. Deploy NVDA mock token
        // ------------------------------------------------------------------
        console2.log("\n--- 1. Deploying NVDA token ---");

        MockERC8056 nvda = new MockERC8056("NVIDIA Corporation", "NVDA", 18);
        console2.log("NVDA deployed at:", address(nvda));

        uint256 initialMultiplier = nvda.uiMultiplier();
        console2.log("Initial uiMultiplier:", initialMultiplier);

        // Mint some shares so we can verify UI balances later
        address holder1 = vm.addr(0x1234);
        nvda.mint(holder1, 100e18);
        console2.log("Minted 100 raw shares to holder:", holder1);
        console2.log("Holder balanceOfUI (pre-split):", nvda.balanceOfUI(holder1));

        // ------------------------------------------------------------------
        // 2. Build split parameters
        // ------------------------------------------------------------------
        console2.log("\n--- 2. Building split parameters ---");

        // 10:1 forward split: numerator=10, denominator=1
        // Expected new multiplier: 1e18 * 10 / 1 = 10e18
        uint256 expectedNewMultiplier = 10e18;

        SplitExecutor.SplitParams memory splitParams = SplitExecutor.SplitParams({
            numerator:            10,
            denominator:          1,
            isReverse:            false,
            expectedNewMultiplier: expectedNewMultiplier,
            fractionalHandling:   0,  // round down (N/A for forward split)
            cashInLieuToken:      address(0),
            cashInLieuPrice:      0
        });

        console2.log("Ratio: 10:1 forward");
        console2.log("Expected new multiplier:", expectedNewMultiplier);

        // ------------------------------------------------------------------
        // 3. Propose the split action
        // ------------------------------------------------------------------
        console2.log("\n--- 3. Proposing NVDA split ---");

        bytes32 intentId = keccak256(
            abi.encodePacked("NVDA-SPLIT-10-1", block.timestamp, deployer)
        );

        ActionIntent memory intent = ActionIntent({
            intentId:           intentId,
            actionType:         ActionType.FORWARD_SPLIT,
            targetToken:        address(nvda),
            ticker:             "NVDA",
            isin:               "US67066G1040",
            recordDate:         block.timestamp,
            exDate:             block.timestamp - 1 days,
            effectiveDate:      block.timestamp + 1 days,
            actionParams:       abi.encode(splitParams),
            sourceAttestation:  bytes32(0),
            state:              ActionState.PROPOSED,
            createdAt:          0,
            executedAt:         0
        });

        console2.log("Intent ID:");
        console2.logBytes32(intentId);

        // Sign and propose
        bytes32 intentHash = keccak256(abi.encode(intent));
        bytes32 ethHash    = MessageHashUtils.toEthSignedMessageHash(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        ActionRegistry registry = ActionRegistry(REGISTRY_ADDR);
        registry.proposeAction(intent, sig);
        console2.log("Split action proposed");

        // ------------------------------------------------------------------
        // 4. Check quorum and queue
        // ------------------------------------------------------------------
        console2.log("\n--- 4. Validation & queueing ---");

        uint256 validations = registry.getValidationCount(intentId);
        ValidatorManager valMgr = ValidatorManager(VALIDATOR_MGR);
        uint256 quorum = valMgr.getQuorum(ActionType.FORWARD_SPLIT);
        console2.log("Validations:", validations, "/ Quorum:", quorum);

        ActionIntent memory stored = registry.getAction(intentId);
        console2.log("State after proposal:", uint256(stored.state));

        if (stored.state == ActionState.VALIDATED) {
            registry.queueAction(intentId);
            console2.log("Action queued for timelock");

            uint256 execTime = registry.getExecutionTime(intentId);
            console2.log("Execution time:", execTime);
        } else {
            console2.log("Needs more validations before queueing");
        }

        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // 5. Warp past timelock and execute (local/fork only)
        // ------------------------------------------------------------------
        console2.log("\n--- 5. Warping past timelock (local demo) ---");

        uint256 execTime = registry.getExecutionTime(intentId);
        if (execTime > 0 && block.timestamp < execTime) {
            vm.warp(execTime + 1);
            console2.log("Warped to:", block.timestamp);
        }

        vm.startBroadcast(deployerKey);
        registry.executeAction(intentId);
        vm.stopBroadcast();

        console2.log("Split executed successfully");

        // ------------------------------------------------------------------
        // 6. Verify results
        // ------------------------------------------------------------------
        console2.log("\n--- 6. Post-split verification ---");

        uint256 newMultiplier = nvda.uiMultiplier();
        console2.log("Old uiMultiplier:", initialMultiplier);
        console2.log("New uiMultiplier:", newMultiplier);
        console2.log("Multiplier ratio:", newMultiplier / initialMultiplier, "x");

        console2.log("");
        console2.log("Holder raw balance:", nvda.balanceOf(holder1));
        console2.log("Holder UI balance :", nvda.balanceOfUI(holder1));
        console2.log("  (should be 10x the pre-split UI balance)");

        ActionIntent memory finalState = registry.getAction(intentId);
        console2.log("");
        console2.log("Final action state:", uint256(finalState.state));
        console2.log("  (4 = EXECUTED)");

        require(newMultiplier == expectedNewMultiplier, "Multiplier mismatch!");
        require(finalState.state == ActionState.EXECUTED, "Action not executed!");

        console2.log("\n============================================");
        console2.log(" NVDA 10:1 split completed successfully");
        console2.log("============================================");
    }
}
