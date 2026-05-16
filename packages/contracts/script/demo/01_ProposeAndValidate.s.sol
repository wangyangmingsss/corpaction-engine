// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  01_ProposeAndValidate
 * @notice Step 1 of the P0 lifecycle demo.
 *
 *   - Deploys MockERC20 (USDC) and MockERC8056 (AAPL)
 *   - Mints AAPL shares to 5 demo holders
 *   - Funds DividendDistributor with USDC
 *   - Builds a Merkle tree for dividend entitlements
 *   - Proposes an AAPL dividend ActionIntent
 *   - Validates until quorum, then queues for timelock
 *
 * Usage:
 *   forge script script/demo/01_ProposeAndValidate.s.sol \
 *       --rpc-url $RPC_URL --broadcast -vvvv
 */

import {Script, console2} from "forge-std/Script.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {ValidatorManager} from "../../src/core/ValidatorManager.sol";
import {DividendDistributor} from "../../src/executors/DividendDistributor.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockERC8056} from "../../test/mocks/MockERC8056.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ProposeAndValidate is Script, ICorpActionTypes {
    // ---- Deployed addresses (Robinhood Chain Testnet) ----
    address constant REGISTRY_ADDR   = 0x1D3c8f75A0822c56FC1d7DDd41106a469f3E1A35;
    address constant VALIDATOR_MGR   = 0xE3fe1728B0Ff8811d1f65Edfe3C9bb58B0a88473;
    address constant DIV_DIST_ADDR   = 0x6f1fCb522466025Cae1e36306993ddA8Befdd01A;

    // ---- Dividend parameters ----
    uint256 constant AMOUNT_PER_SHARE = 0.50e6;   // $0.50 USDC per share
    uint256 constant CLAIM_WINDOW     = 30 days;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerKey);

        console2.log("============================================");
        console2.log(" Step 1: Propose & Validate AAPL Dividend");
        console2.log("============================================");
        console2.log("Deployer / Validator:", deployer);

        vm.startBroadcast(deployerKey);

        // ------------------------------------------------------------------
        // 1. Deploy mock tokens
        // ------------------------------------------------------------------
        console2.log("\n--- 1. Deploying mock tokens ---");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console2.log("USDC deployed at:", address(usdc));

        MockERC8056 aapl = new MockERC8056("Apple Inc.", "AAPL", 18);
        console2.log("AAPL deployed at:", address(aapl));

        // ------------------------------------------------------------------
        // 2. Create 5 holder addresses and mint AAPL
        // ------------------------------------------------------------------
        console2.log("\n--- 2. Creating holders & minting AAPL ---");

        address alice   = vm.addr(0xA11CE);
        address bob     = vm.addr(0xB0B);
        address charlie = vm.addr(0xC4A7);
        address dave    = vm.addr(0xDA7E);
        address eve     = vm.addr(0xE7E);

        // Share counts (in token base units, 18 decimals)
        uint256 aliceShares   = 100e18;
        uint256 bobShares     = 250e18;
        uint256 charlieShares = 50e18;
        uint256 daveShares    = 75e18;
        uint256 eveShares     = 25e18;

        aapl.mint(alice,   aliceShares);
        aapl.mint(bob,     bobShares);
        aapl.mint(charlie, charlieShares);
        aapl.mint(dave,    daveShares);
        aapl.mint(eve,     eveShares);

        console2.log("Alice   :", alice,   "->", aliceShares / 1e18, "shares");
        console2.log("Bob     :", bob,     "->", bobShares / 1e18, "shares");
        console2.log("Charlie :", charlie, "->", charlieShares / 1e18, "shares");
        console2.log("Dave    :", dave,    "->", daveShares / 1e18, "shares");
        console2.log("Eve     :", eve,     "->", eveShares / 1e18, "shares");

        // ------------------------------------------------------------------
        // 3. Compute dividend amounts and Merkle tree
        // ------------------------------------------------------------------
        console2.log("\n--- 3. Building Merkle tree ---");

        // Dividend amounts: shares (in whole units) * AMOUNT_PER_SHARE
        uint256 aliceDiv   = 100 * AMOUNT_PER_SHARE;  //  50 USDC
        uint256 bobDiv     = 250 * AMOUNT_PER_SHARE;  // 125 USDC
        uint256 charlieDiv = 50  * AMOUNT_PER_SHARE;  //  25 USDC
        uint256 daveDiv    = 75  * AMOUNT_PER_SHARE;  //  37.5 USDC
        uint256 eveDiv     = 25  * AMOUNT_PER_SHARE;  //  12.5 USDC
        uint256 totalDiv   = aliceDiv + bobDiv + charlieDiv + daveDiv + eveDiv;

        console2.log("Total dividend pool:", totalDiv / 1e6, "USDC");

        // Leaf computation matches MerkleDistributor.computeLeaf:
        //   keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
        bytes32 leafAlice   = keccak256(bytes.concat(keccak256(abi.encode(alice,   aliceDiv))));
        bytes32 leafBob     = keccak256(bytes.concat(keccak256(abi.encode(bob,     bobDiv))));
        bytes32 leafCharlie = keccak256(bytes.concat(keccak256(abi.encode(charlie, charlieDiv))));
        bytes32 leafDave    = keccak256(bytes.concat(keccak256(abi.encode(dave,    daveDiv))));
        bytes32 leafEve     = keccak256(bytes.concat(keccak256(abi.encode(eve,     eveDiv))));

        // Build a simple balanced Merkle tree (5 leaves, padded to 8)
        // Layer 0 (leaves sorted for deterministic root):
        bytes32[8] memory leaves;
        leaves[0] = leafAlice;
        leaves[1] = leafBob;
        leaves[2] = leafCharlie;
        leaves[3] = leafDave;
        leaves[4] = leafEve;
        leaves[5] = bytes32(0); // padding
        leaves[6] = bytes32(0);
        leaves[7] = bytes32(0);

        // Layer 1
        bytes32[4] memory layer1;
        for (uint256 i = 0; i < 4; i++) {
            layer1[i] = _hashPair(leaves[i * 2], leaves[i * 2 + 1]);
        }
        // Layer 2
        bytes32[2] memory layer2;
        layer2[0] = _hashPair(layer1[0], layer1[1]);
        layer2[1] = _hashPair(layer1[2], layer1[3]);

        // Root
        bytes32 merkleRoot = _hashPair(layer2[0], layer2[1]);

        console2.log("Merkle root:");
        console2.logBytes32(merkleRoot);

        // ------------------------------------------------------------------
        // 4. Fund DividendDistributor with USDC
        // ------------------------------------------------------------------
        console2.log("\n--- 4. Funding DividendDistributor ---");

        usdc.mint(DIV_DIST_ADDR, totalDiv);
        console2.log("Minted", totalDiv / 1e6, "USDC to DividendDistributor");
        console2.log("Distributor balance:", IERC20(address(usdc)).balanceOf(DIV_DIST_ADDR) / 1e6, "USDC");

        // ------------------------------------------------------------------
        // 5. Build ActionIntent and propose
        // ------------------------------------------------------------------
        console2.log("\n--- 5. Proposing AAPL dividend action ---");

        bytes32 intentId = keccak256(
            abi.encodePacked("AAPL-DIV-2026Q2", block.timestamp, deployer)
        );

        DividendDistributor.DividendParams memory divParams = DividendDistributor.DividendParams({
            paymentToken:    address(usdc),
            totalAmount:     totalDiv,
            amountPerShare:  AMOUNT_PER_SHARE,
            merkleRoot:      merkleRoot,
            snapshotBlock:   block.number,
            claimDeadline:   block.timestamp + CLAIM_WINDOW,
            withholding:     false,
            withholdingBps:  0
        });

        ActionIntent memory intent = ActionIntent({
            intentId:           intentId,
            actionType:         ActionType.DIVIDEND,
            targetToken:        address(aapl),
            ticker:             "AAPL",
            isin:               "US0378331005",
            recordDate:         block.timestamp,
            exDate:             block.timestamp - 1 days,
            effectiveDate:      block.timestamp + 1 days,
            actionParams:       abi.encode(divParams),
            sourceAttestation:  bytes32(0),
            state:              ActionState.PROPOSED,
            createdAt:          0,
            executedAt:         0
        });

        console2.log("Intent ID:");
        console2.logBytes32(intentId);

        // Sign the intent (deployer is a registered validator)
        bytes32 intentHash = keccak256(abi.encode(intent));
        bytes32 ethHash    = MessageHashUtils.toEthSignedMessageHash(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, ethHash);
        bytes memory proposalSig = abi.encodePacked(r, s, v);

        ActionRegistry registry = ActionRegistry(REGISTRY_ADDR);
        registry.proposeAction(intent, proposalSig);
        console2.log("Action proposed successfully");

        // ------------------------------------------------------------------
        // 6. Check validation count and quorum
        // ------------------------------------------------------------------
        console2.log("\n--- 6. Checking validation status ---");

        uint256 validationCount = registry.getValidationCount(intentId);
        ValidatorManager valMgr = ValidatorManager(VALIDATOR_MGR);
        uint256 requiredQuorum  = valMgr.getQuorum(ActionType.DIVIDEND);

        console2.log("Validations so far:", validationCount);
        console2.log("Required quorum:   ", requiredQuorum);

        // If quorum is already met (single-validator testnet), the state
        // transitions to VALIDATED automatically via _checkQuorum.
        ActionIntent memory stored = registry.getAction(intentId);
        console2.log("Current state:     ", uint256(stored.state));

        // ------------------------------------------------------------------
        // 7. Queue the action for timelock
        // ------------------------------------------------------------------
        if (stored.state == ActionState.VALIDATED) {
            console2.log("\n--- 7. Queuing action for timelock ---");
            registry.queueAction(intentId);

            uint256 execTime = registry.getExecutionTime(intentId);
            console2.log("Execution time:", execTime);
            console2.log("Current time:  ", block.timestamp);
            console2.log("Delta (sec):   ", execTime - block.timestamp);
        } else {
            console2.log("\n--- 7. Skipped queuing (needs more validations) ---");
            console2.log("   Add more validators and call validateAction().");
        }

        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // 8. Summary -- export these for subsequent scripts
        // ------------------------------------------------------------------
        console2.log("\n============================================");
        console2.log(" Export these env vars for Steps 2-3:");
        console2.log("============================================");
        console2.log("INTENT_ID  =");
        console2.logBytes32(intentId);
        console2.log("AAPL_TOKEN =", address(aapl));
        console2.log("USDC_TOKEN =", address(usdc));
        console2.log("============================================");
    }

    /// @dev Hash pair helper for Merkle tree construction (sorted).
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }
}
