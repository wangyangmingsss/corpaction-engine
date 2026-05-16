// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  FullDividendDemo
 * @notice Comprehensive single-script walkthrough (Section 6.1 of upgrade doc).
 *
 *   Deploys everything fresh and runs the entire dividend lifecycle in one
 *   transaction, using vm.warp to skip timelocks.  Intended for local Anvil
 *   or fork testing -- not live broadcast.
 *
 *   Lifecycle covered:
 *     1. Deploy infrastructure (ValidatorManager, ActionRegistry, executors)
 *     2. Deploy mock tokens (USDC, AAPL)
 *     3. Mint shares to 5 holders
 *     4. Fund DividendDistributor
 *     5. Propose dividend action
 *     6. Validate & auto-queue
 *     7. vm.warp past timelock
 *     8. Execute dividend
 *     9. Each holder claims
 *    10. Verify final balances
 *
 * Usage:
 *   forge script script/demo/FullDividendDemo.s.sol -vvvv
 */

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {ValidatorManager} from "../../src/core/ValidatorManager.sol";
import {TimelockController} from "../../src/core/TimelockController.sol";
import {DividendDistributor} from "../../src/executors/DividendDistributor.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockERC8056} from "../../test/mocks/MockERC8056.sol";

contract FullDividendDemo is Script, ICorpActionTypes {
    // ---- Demo constants ----
    uint256 constant AMOUNT_PER_SHARE = 0.50e6;   // $0.50 per share in USDC
    uint256 constant CLAIM_WINDOW     = 30 days;
    uint256 constant TIMELOCK_DELAY   = 1 hours;   // short for demo
    uint256 constant INTENT_TTL       = 7 days;

    // ---- Holder private keys (deterministic for demo) ----
    uint256 constant ALICE_KEY   = 0xA11CE;
    uint256 constant BOB_KEY     = 0xB0B;
    uint256 constant CHARLIE_KEY = 0xC4A7;
    uint256 constant DAVE_KEY    = 0xDA7E;
    uint256 constant EVE_KEY     = 0xE7E;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("==========================================================");
        console2.log(" FullDividendDemo -- Complete Lifecycle in One Script");
        console2.log("==========================================================");
        console2.log("Deployer:", deployer);
        console2.log("Timestamp:", block.timestamp);
        console2.log("");

        vm.startBroadcast(deployerKey);

        // ================================================================
        // PHASE 1: Deploy Infrastructure
        // ================================================================
        console2.log("---------- PHASE 1: Deploy Infrastructure ----------");

        // -- ValidatorManager --
        ValidatorManager valImpl = new ValidatorManager();
        address[] memory validators = new address[](1);
        validators[0] = deployer;
        ERC1967Proxy valProxy = new ERC1967Proxy(
            address(valImpl),
            abi.encodeWithSelector(ValidatorManager.initialize.selector, validators, 1)
        );
        ValidatorManager valMgr = ValidatorManager(address(valProxy));
        console2.log("ValidatorManager:", address(valMgr));

        // Set quorum to 1 for demo (single validator)
        valMgr.setQuorum(ActionType.DIVIDEND, 1);
        console2.log("  Dividend quorum set to 1");

        // -- ActionRegistry --
        ActionRegistry regImpl = new ActionRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeWithSelector(ActionRegistry.initialize.selector, address(valMgr), INTENT_TTL)
        );
        ActionRegistry registry = ActionRegistry(address(regProxy));
        console2.log("ActionRegistry:", address(registry));

        // Set a short timelock for demo
        registry.setTimelock(ActionType.DIVIDEND, TIMELOCK_DELAY);
        console2.log("  Dividend timelock:", TIMELOCK_DELAY, "seconds");

        // -- DividendDistributor --
        DividendDistributor divImpl = new DividendDistributor();
        ERC1967Proxy divProxy = new ERC1967Proxy(
            address(divImpl),
            abi.encodeWithSelector(DividendDistributor.initialize.selector, address(registry), deployer)
        );
        DividendDistributor divDist = DividendDistributor(address(divProxy));
        console2.log("DividendDistributor:", address(divDist));

        // Register executor
        registry.registerExecutor(ActionType.DIVIDEND, address(divDist));
        console2.log("  Registered as DIVIDEND executor");

        // ================================================================
        // PHASE 2: Deploy Mock Tokens
        // ================================================================
        console2.log("\n---------- PHASE 2: Deploy Mock Tokens ----------");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console2.log("USDC:", address(usdc));

        MockERC8056 aapl = new MockERC8056("Apple Inc.", "AAPL", 18);
        console2.log("AAPL:", address(aapl));

        // ================================================================
        // PHASE 3: Mint Shares to Holders
        // ================================================================
        console2.log("\n---------- PHASE 3: Mint Shares ----------");

        address alice   = vm.addr(ALICE_KEY);
        address bob     = vm.addr(BOB_KEY);
        address charlie = vm.addr(CHARLIE_KEY);
        address dave    = vm.addr(DAVE_KEY);
        address eve     = vm.addr(EVE_KEY);

        aapl.mint(alice,   100e18);
        aapl.mint(bob,     250e18);
        aapl.mint(charlie, 50e18);
        aapl.mint(dave,    75e18);
        aapl.mint(eve,     25e18);

        console2.log("Alice   :", alice,   "-> 100 shares");
        console2.log("Bob     :", bob,     "-> 250 shares");
        console2.log("Charlie :", charlie, "->  50 shares");
        console2.log("Dave    :", dave,    "->  75 shares");
        console2.log("Eve     :", eve,     "->  25 shares");
        console2.log("Total   : 500 shares");

        // ================================================================
        // PHASE 4: Compute Dividends & Merkle Tree
        // ================================================================
        console2.log("\n---------- PHASE 4: Merkle Tree ----------");

        uint256 aliceDiv   = 100 * AMOUNT_PER_SHARE;
        uint256 bobDiv     = 250 * AMOUNT_PER_SHARE;
        uint256 charlieDiv = 50  * AMOUNT_PER_SHARE;
        uint256 daveDiv    = 75  * AMOUNT_PER_SHARE;
        uint256 eveDiv     = 25  * AMOUNT_PER_SHARE;
        uint256 totalDiv   = aliceDiv + bobDiv + charlieDiv + daveDiv + eveDiv;

        console2.log("Total dividend pool:", totalDiv / 1e6, "USDC");

        // Build leaves (matching MerkleDistributor.computeLeaf)
        bytes32[8] memory leaves;
        leaves[0] = keccak256(bytes.concat(keccak256(abi.encode(alice,   aliceDiv))));
        leaves[1] = keccak256(bytes.concat(keccak256(abi.encode(bob,     bobDiv))));
        leaves[2] = keccak256(bytes.concat(keccak256(abi.encode(charlie, charlieDiv))));
        leaves[3] = keccak256(bytes.concat(keccak256(abi.encode(dave,    daveDiv))));
        leaves[4] = keccak256(bytes.concat(keccak256(abi.encode(eve,     eveDiv))));
        leaves[5] = bytes32(0);
        leaves[6] = bytes32(0);
        leaves[7] = bytes32(0);

        bytes32[4] memory L1;
        for (uint256 i = 0; i < 4; i++) {
            L1[i] = _hashPair(leaves[i * 2], leaves[i * 2 + 1]);
        }
        bytes32[2] memory L2;
        L2[0] = _hashPair(L1[0], L1[1]);
        L2[1] = _hashPair(L1[2], L1[3]);
        bytes32 merkleRoot = _hashPair(L2[0], L2[1]);

        console2.log("Merkle root:");
        console2.logBytes32(merkleRoot);

        // ================================================================
        // PHASE 5: Fund Distributor
        // ================================================================
        console2.log("\n---------- PHASE 5: Fund Distributor ----------");

        usdc.mint(address(divDist), totalDiv);
        console2.log("Funded distributor with", totalDiv / 1e6, "USDC");

        // ================================================================
        // PHASE 6: Propose Dividend Action
        // ================================================================
        console2.log("\n---------- PHASE 6: Propose Action ----------");

        bytes32 intentId = keccak256(
            abi.encodePacked("AAPL-DIV-FULL-DEMO", block.timestamp, deployer)
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

        bytes32 intentHash = keccak256(abi.encode(intent));
        bytes32 ethHash    = MessageHashUtils.toEthSignedMessageHash(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        registry.proposeAction(intent, sig);
        console2.log("Action proposed");

        // With quorum=1, the action auto-transitions to VALIDATED
        ActionIntent memory afterPropose = registry.getAction(intentId);
        console2.log("State after propose:", uint256(afterPropose.state));
        require(afterPropose.state == ActionState.VALIDATED, "Should be VALIDATED with quorum=1");

        // ================================================================
        // PHASE 7: Queue & Warp Past Timelock
        // ================================================================
        console2.log("\n---------- PHASE 7: Queue & Warp ----------");

        registry.queueAction(intentId);
        uint256 execTime = registry.getExecutionTime(intentId);
        console2.log("Queued. Execution time:", execTime);

        vm.stopBroadcast();

        // Warp past the timelock
        vm.warp(execTime + 1);
        console2.log("Warped to:", block.timestamp);

        // ================================================================
        // PHASE 8: Execute Dividend
        // ================================================================
        console2.log("\n---------- PHASE 8: Execute ----------");

        vm.startBroadcast(deployerKey);
        registry.executeAction(intentId);
        vm.stopBroadcast();

        ActionIntent memory afterExec = registry.getAction(intentId);
        console2.log("State after execute:", uint256(afterExec.state));
        require(afterExec.state == ActionState.EXECUTED, "Should be EXECUTED");
        console2.log("Dividend distribution initialized on-chain");

        // ================================================================
        // PHASE 9: Claims
        // ================================================================
        console2.log("\n---------- PHASE 9: Holder Claims ----------");

        _claimAndLog(divDist, usdc, intentId, alice,   ALICE_KEY,   aliceDiv,   "Alice",   _proof(leaves, L1, L2, 0));
        _claimAndLog(divDist, usdc, intentId, bob,     BOB_KEY,     bobDiv,     "Bob",     _proof(leaves, L1, L2, 1));
        _claimAndLog(divDist, usdc, intentId, charlie, CHARLIE_KEY, charlieDiv, "Charlie", _proof(leaves, L1, L2, 2));
        _claimAndLog(divDist, usdc, intentId, dave,    DAVE_KEY,    daveDiv,    "Dave",    _proof(leaves, L1, L2, 3));
        _claimAndLog(divDist, usdc, intentId, eve,     EVE_KEY,     eveDiv,     "Eve",     _proof(leaves, L1, L2, 4));

        // ================================================================
        // PHASE 10: Verify Final Balances
        // ================================================================
        console2.log("\n---------- PHASE 10: Final Verification ----------");

        require(usdc.balanceOf(alice)   == aliceDiv,   "Alice balance mismatch");
        require(usdc.balanceOf(bob)     == bobDiv,     "Bob balance mismatch");
        require(usdc.balanceOf(charlie) == charlieDiv, "Charlie balance mismatch");
        require(usdc.balanceOf(dave)    == daveDiv,    "Dave balance mismatch");
        require(usdc.balanceOf(eve)     == eveDiv,     "Eve balance mismatch");

        console2.log("All balances verified correctly");
        console2.log("");
        console2.log("Alice   :", usdc.balanceOf(alice)   / 1e6, "USDC");
        console2.log("Bob     :", usdc.balanceOf(bob)     / 1e6, "USDC");
        console2.log("Charlie :", usdc.balanceOf(charlie) / 1e6, "USDC");
        console2.log("Dave    :", usdc.balanceOf(dave)    / 1e6, "USDC");
        console2.log("Eve     :", usdc.balanceOf(eve)     / 1e6, "USDC");
        console2.log("Distributor remaining:", usdc.balanceOf(address(divDist)) / 1e6, "USDC");

        console2.log("\n==========================================================");
        console2.log(" FullDividendDemo PASSED -- all 10 phases complete");
        console2.log("==========================================================");
    }

    // ---- Helpers ----

    function _claimAndLog(
        DividendDistributor divDist,
        IERC20 usdc,
        bytes32 intentId,
        address holder,
        uint256 holderKey,
        uint256 amount,
        string memory name,
        bytes32[] memory proof
    ) internal {
        uint256 balBefore = usdc.balanceOf(holder);

        vm.startBroadcast(holderKey);
        divDist.claimDividend(intentId, amount, proof);
        vm.stopBroadcast();

        uint256 received = usdc.balanceOf(holder) - balBefore;
        console2.log(name, "claimed", received / 1e6, "USDC");
    }

    function _proof(
        bytes32[8] memory leaves,
        bytes32[4] memory L1,
        bytes32[2] memory L2,
        uint256 index
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory p = new bytes32[](3);

        uint256 sib0 = (index % 2 == 0) ? index + 1 : index - 1;
        p[0] = leaves[sib0];

        uint256 l1Idx = index / 2;
        uint256 sib1  = (l1Idx % 2 == 0) ? l1Idx + 1 : l1Idx - 1;
        p[1] = L1[sib1];

        uint256 l2Idx = l1Idx / 2;
        uint256 sib2  = (l2Idx % 2 == 0) ? l2Idx + 1 : l2Idx - 1;
        p[2] = L2[sib2];

        return p;
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }
}
