// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  03_ClaimDividend
 * @notice Step 3 of the P0 lifecycle demo.
 *
 *   - Reconstructs the same 5 holder addresses used in Step 1
 *   - Each holder claims their dividend via Merkle proof
 *   - Verifies USDC balances after each claim
 *
 * Prerequisites:
 *   - Step 1 completed (tokens deployed, action proposed)
 *   - Step 2 completed (action executed, dividend initialized)
 *
 * Usage:
 *   INTENT_ID=0x... USDC_TOKEN=0x... \
 *     forge script script/demo/03_ClaimDividend.s.sol \
 *       --rpc-url $RPC_URL --broadcast -vvvv
 */

import {Script, console2} from "forge-std/Script.sol";
import {DividendDistributor} from "../../src/executors/DividendDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ClaimDividend is Script {
    address constant DIV_DIST_ADDR = 0x6f1fCb522466025Cae1e36306993ddA8Befdd01A;

    // Same AMOUNT_PER_SHARE as Step 1
    uint256 constant AMOUNT_PER_SHARE = 0.50e6;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        bytes32 intentId    = vm.envBytes32("INTENT_ID");
        address usdcAddr    = vm.envAddress("USDC_TOKEN");

        console2.log("============================================");
        console2.log(" Step 3: Claim Dividends");
        console2.log("============================================");
        console2.log("Intent ID:");
        console2.logBytes32(intentId);
        console2.log("USDC:", usdcAddr);

        DividendDistributor divDist = DividendDistributor(DIV_DIST_ADDR);
        IERC20 usdc = IERC20(usdcAddr);

        // ------------------------------------------------------------------
        // 1. Reconstruct holders and amounts (must match Step 1 exactly)
        // ------------------------------------------------------------------
        address alice   = vm.addr(0xA11CE);
        address bob     = vm.addr(0xB0B);
        address charlie = vm.addr(0xC4A7);
        address dave    = vm.addr(0xDA7E);
        address eve     = vm.addr(0xE7E);

        uint256 aliceDiv   = 100 * AMOUNT_PER_SHARE;
        uint256 bobDiv     = 250 * AMOUNT_PER_SHARE;
        uint256 charlieDiv = 50  * AMOUNT_PER_SHARE;
        uint256 daveDiv    = 75  * AMOUNT_PER_SHARE;
        uint256 eveDiv     = 25  * AMOUNT_PER_SHARE;

        // ------------------------------------------------------------------
        // 2. Rebuild Merkle tree to generate proofs
        // ------------------------------------------------------------------
        console2.log("\n--- Rebuilding Merkle tree for proofs ---");

        bytes32 leafAlice   = keccak256(bytes.concat(keccak256(abi.encode(alice,   aliceDiv))));
        bytes32 leafBob     = keccak256(bytes.concat(keccak256(abi.encode(bob,     bobDiv))));
        bytes32 leafCharlie = keccak256(bytes.concat(keccak256(abi.encode(charlie, charlieDiv))));
        bytes32 leafDave    = keccak256(bytes.concat(keccak256(abi.encode(dave,    daveDiv))));
        bytes32 leafEve     = keccak256(bytes.concat(keccak256(abi.encode(eve,     eveDiv))));

        bytes32[8] memory leaves;
        leaves[0] = leafAlice;
        leaves[1] = leafBob;
        leaves[2] = leafCharlie;
        leaves[3] = leafDave;
        leaves[4] = leafEve;
        leaves[5] = bytes32(0);
        leaves[6] = bytes32(0);
        leaves[7] = bytes32(0);

        // Layer 1
        bytes32[4] memory L1;
        for (uint256 i = 0; i < 4; i++) {
            L1[i] = _hashPair(leaves[i * 2], leaves[i * 2 + 1]);
        }
        // Layer 2
        bytes32[2] memory L2;
        L2[0] = _hashPair(L1[0], L1[1]);
        L2[1] = _hashPair(L1[2], L1[3]);

        // ------------------------------------------------------------------
        // 3. Claim for each holder
        // ------------------------------------------------------------------
        console2.log("\n--- Claiming dividends ---");

        // Alice: proof = [leafBob-sibling, L1[1], L2[1]]
        _claimFor(
            divDist, usdc, intentId,
            alice, 0xA11CE, aliceDiv,
            "Alice",
            _buildProof(leaves, L1, L2, 0)
        );

        // Bob
        _claimFor(
            divDist, usdc, intentId,
            bob, 0xB0B, bobDiv,
            "Bob",
            _buildProof(leaves, L1, L2, 1)
        );

        // Charlie
        _claimFor(
            divDist, usdc, intentId,
            charlie, 0xC4A7, charlieDiv,
            "Charlie",
            _buildProof(leaves, L1, L2, 2)
        );

        // Dave
        _claimFor(
            divDist, usdc, intentId,
            dave, 0xDA7E, daveDiv,
            "Dave",
            _buildProof(leaves, L1, L2, 3)
        );

        // Eve
        _claimFor(
            divDist, usdc, intentId,
            eve, 0xE7E, eveDiv,
            "Eve",
            _buildProof(leaves, L1, L2, 4)
        );

        // ------------------------------------------------------------------
        // 4. Final summary
        // ------------------------------------------------------------------
        console2.log("\n============================================");
        console2.log(" All claims complete. Final USDC balances:");
        console2.log("============================================");
        console2.log("Alice   :", usdc.balanceOf(alice)   / 1e6, "USDC");
        console2.log("Bob     :", usdc.balanceOf(bob)     / 1e6, "USDC");
        console2.log("Charlie :", usdc.balanceOf(charlie) / 1e6, "USDC");
        console2.log("Dave    :", usdc.balanceOf(dave)    / 1e6, "USDC");
        console2.log("Eve     :", usdc.balanceOf(eve)     / 1e6, "USDC");
        console2.log("============================================");
    }

    /// @dev Claim dividend for a specific holder, broadcasting from their key.
    function _claimFor(
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

        uint256 balAfter = usdc.balanceOf(holder);
        uint256 received = balAfter - balBefore;

        console2.log(name, "claimed", received / 1e6, "USDC");
    }

    /// @dev Build a Merkle proof for leaf at `index` in a depth-3 tree (8 leaves).
    function _buildProof(
        bytes32[8] memory leaves,
        bytes32[4] memory L1,
        bytes32[2] memory L2,
        uint256 index
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](3);

        // Sibling at layer 0
        uint256 siblingIdx = (index % 2 == 0) ? index + 1 : index - 1;
        proof[0] = leaves[siblingIdx];

        // Sibling at layer 1
        uint256 l1Idx    = index / 2;
        uint256 l1Sib    = (l1Idx % 2 == 0) ? l1Idx + 1 : l1Idx - 1;
        proof[1] = L1[l1Sib];

        // Sibling at layer 2
        uint256 l2Idx    = l1Idx / 2;
        uint256 l2Sib    = (l2Idx % 2 == 0) ? l2Idx + 1 : l2Idx - 1;
        proof[2] = L2[l2Sib];

        return proof;
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }
}
