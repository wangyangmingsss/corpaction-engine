// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ============================================================================
 *  CorpAction Engine -- P0 End-to-End Lifecycle Demo (Overview)
 * ============================================================================
 *
 *  This file documents the full lifecycle of a corporate action on the
 *  Robinhood Chain Testnet.  It is NOT meant to be executed directly --
 *  instead, run the numbered scripts in order:
 *
 *  Step 1 -- 01_ProposeAndValidate.s.sol
 *      - Deploys mock tokens (USDC + AAPL ERC-8056)
 *      - Mints shares to 5 demo holders
 *      - Funds the DividendDistributor with USDC
 *      - Builds a Merkle tree for dividend claims
 *      - Proposes an AAPL cash-dividend ActionIntent
 *      - Validator(s) validate the proposal until quorum is reached
 *      - Queues the action for timelock
 *
 *  Step 2 -- 02_ExecuteAfterTimelock.s.sol
 *      - Reads the intentId from the environment
 *      - Waits until the timelock period has elapsed
 *      - Calls registry.executeAction(intentId)
 *      - Verifies the DividendDistributor state
 *
 *  Step 3 -- 03_ClaimDividend.s.sol
 *      - Each of the 5 holders claims their dividend via Merkle proof
 *      - Verifies USDC balances after claims
 *
 *  Step 4 -- 04_ExecuteSplit.s.sol
 *      - Proposes an NVDA 10:1 forward split
 *      - Validates, queues, and executes (vm.warp for local demo)
 *      - Verifies the uiMultiplier changed correctly
 *
 *  --------------------------------------------------------------------------
 *  Deployed Contract Addresses (Robinhood Chain Testnet)
 *  --------------------------------------------------------------------------
 *  ActionRegistry        : 0x1D3c8f75A0822c56FC1d7DDd41106a469f3E1A35
 *  ValidatorManager      : 0xE3fe1728B0Ff8811d1f65Edfe3C9bb58B0a88473
 *  DividendDistributor   : 0x6f1fCb522466025Cae1e36306993ddA8Befdd01A
 *  SplitExecutor         : 0x710a6aCf4C11eD4E80baCE15C50193328A3c73E4
 *  --------------------------------------------------------------------------
 *
 *  Environment variables required:
 *      PRIVATE_KEY        -- Deployer / validator private key
 *      RPC_URL            -- Robinhood Chain Testnet RPC
 *      INTENT_ID          -- (Steps 2-3) Output from Step 1
 *      AAPL_TOKEN         -- (Steps 2-3) MockERC8056 address from Step 1
 *      USDC_TOKEN         -- (Steps 2-3) MockERC20 address from Step 1
 *
 *  Example invocation:
 *      forge script script/demo/01_ProposeAndValidate.s.sol \
 *          --rpc-url $RPC_URL --broadcast -vvvv
 */

import {Script, console2} from "forge-std/Script.sol";

contract ExecuteFullLifecycle is Script {
    function run() external pure {
        console2.log("==========================================================");
        console2.log(" CorpAction Engine -- Full Lifecycle Overview");
        console2.log("==========================================================");
        console2.log("");
        console2.log(" This is a documentation-only script.");
        console2.log(" Run the numbered scripts (01-04) in order.");
        console2.log("");
        console2.log(" Or run FullDividendDemo.s.sol for a single-tx walkthrough");
        console2.log(" that deploys everything fresh and uses vm.warp.");
        console2.log("==========================================================");
    }
}
