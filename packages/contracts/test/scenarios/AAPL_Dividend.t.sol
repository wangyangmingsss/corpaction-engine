// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DividendDistributor} from "../../src/executors/DividendDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title AAPL Quarterly Dividend Replay
/// @notice Simulates Apple's Q1 2026 quarterly dividend of $0.25/share
contract AAPL_DividendTest is Test {
    DividendDistributor public distributor;
    MockERC20 public usdc;
    MockERC20 public aaplToken;

    address public registry = address(this);
    address public treasury = makeAddr("treasury");

    // Simulated holders with realistic share counts
    address public retailHolder = makeAddr("retailHolder");       // 50 shares
    address public institutionalHolder = makeAddr("institutional"); // 10,000 shares
    address public indexFund = makeAddr("indexFund");              // 50,000 shares

    uint256 constant DIVIDEND_PER_SHARE = 250_000; // $0.25 in USDC (6 decimals)
    uint256 constant RETAIL_AMOUNT = 50 * DIVIDEND_PER_SHARE;         // $12.50
    uint256 constant INST_AMOUNT = 10_000 * DIVIDEND_PER_SHARE;       // $2,500
    uint256 constant INDEX_AMOUNT = 50_000 * DIVIDEND_PER_SHARE;      // $12,500
    uint256 constant TOTAL_POOL = RETAIL_AMOUNT + INST_AMOUNT + INDEX_AMOUNT;

    bytes32 public merkleRoot;
    bytes32[] public retailProof;
    bytes32[] public instProof;
    bytes32[] public indexProof;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        aaplToken = new MockERC20("Apple Inc.", "AAPL", 18);

        DividendDistributor impl = new DividendDistributor();
        bytes memory initData = abi.encodeWithSelector(
            DividendDistributor.initialize.selector, registry, treasury
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        distributor = DividendDistributor(address(proxy));

        usdc.mint(address(distributor), TOTAL_POOL);

        aaplToken.mint(retailHolder, 50e18);
        aaplToken.mint(institutionalHolder, 10_000e18);
        aaplToken.mint(indexFund, 50_000e18);

        // Build 3-leaf merkle tree
        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(retailHolder, RETAIL_AMOUNT))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(institutionalHolder, INST_AMOUNT))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(indexFund, INDEX_AMOUNT))));

        // Layer 1: pair first two
        bytes32 pair01 = leaf0 <= leaf1
            ? keccak256(abi.encodePacked(leaf0, leaf1))
            : keccak256(abi.encodePacked(leaf1, leaf0));

        // Root
        merkleRoot = pair01 <= leaf2
            ? keccak256(abi.encodePacked(pair01, leaf2))
            : keccak256(abi.encodePacked(leaf2, pair01));

        // Proofs
        retailProof = new bytes32[](2);
        retailProof[0] = leaf1;
        retailProof[1] = leaf2;

        instProof = new bytes32[](2);
        instProof[0] = leaf0;
        instProof[1] = leaf2;

        indexProof = new bytes32[](1);
        indexProof[0] = pair01;
    }

    function _initDividend() internal returns (bytes32) {
        bytes32 intentId = keccak256("aapl-q1-2026-dividend");

        bytes memory actionParams = abi.encode(
            address(usdc),
            TOTAL_POOL,
            DIVIDEND_PER_SHARE,
            merkleRoot,
            block.number,
            block.timestamp + 90 days, // claim deadline
            false,
            uint256(0)
        );

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(aaplToken),
            ticker: "AAPL",
            isin: "US0378331005",
            recordDate: block.timestamp,
            exDate: block.timestamp - 1 days,
            effectiveDate: block.timestamp + 30 days,
            actionParams: actionParams,
            sourceAttestation: keccak256("sec-edgar-aapl-8k-q1-2026"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        distributor.execute(intent);
        return intentId;
    }

    function test_aaplQuarterlyDividend_allHoldersClaim() public {
        bytes32 intentId = _initDividend();

        // Retail holder claims $12.50
        vm.prank(retailHolder);
        distributor.claimDividend(intentId, RETAIL_AMOUNT, retailProof);
        assertEq(usdc.balanceOf(retailHolder), RETAIL_AMOUNT);

        // Institutional holder claims $2,500
        vm.prank(institutionalHolder);
        distributor.claimDividend(intentId, INST_AMOUNT, instProof);
        assertEq(usdc.balanceOf(institutionalHolder), INST_AMOUNT);

        // Index fund claims $12,500
        vm.prank(indexFund);
        distributor.claimDividend(intentId, INDEX_AMOUNT, indexProof);
        assertEq(usdc.balanceOf(indexFund), INDEX_AMOUNT);

        // Verify pool fully distributed
        (,,uint256 totalClaimed,,) = distributor.dividends(intentId);
        assertEq(totalClaimed, TOTAL_POOL);
    }

    function test_aaplDividend_partialClaimThenReclaim() public {
        bytes32 intentId = _initDividend();

        // Only retail claims
        vm.prank(retailHolder);
        distributor.claimDividend(intentId, RETAIL_AMOUNT, retailProof);

        // Warp past deadline
        vm.warp(block.timestamp + 91 days);

        // Reclaim unclaimed funds to treasury
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        distributor.reclaimExpired(intentId);

        uint256 reclaimed = usdc.balanceOf(treasury) - treasuryBefore;
        assertEq(reclaimed, TOTAL_POOL - RETAIL_AMOUNT);
    }
}
