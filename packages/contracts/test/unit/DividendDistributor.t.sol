// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DividendDistributor} from "../../src/executors/DividendDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DividendDistributorTest is Test {
    DividendDistributor public distributor;
    MockERC20 public usdc;
    MockERC20 public stockToken;

    address public registry = address(this);
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public intentId = keccak256("div-test");
    uint256 public aliceAmount = 25e6;
    uint256 public bobAmount = 62_500_000;

    bytes32 public merkleRoot;
    bytes32[] public aliceProof;
    bytes32[] public bobProof;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        stockToken = new MockERC20("AAPL", "AAPL", 18);

        DividendDistributor impl = new DividendDistributor();
        bytes memory initData = abi.encodeWithSelector(
            DividendDistributor.initialize.selector, registry, treasury
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        distributor = DividendDistributor(address(proxy));

        usdc.mint(address(distributor), 10_000e6);

        // Build merkle tree
        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 bobLeaf = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmount))));

        aliceProof = new bytes32[](1);
        bobProof = new bytes32[](1);

        if (aliceLeaf <= bobLeaf) {
            merkleRoot = keccak256(abi.encodePacked(aliceLeaf, bobLeaf));
            aliceProof[0] = bobLeaf;
            bobProof[0] = aliceLeaf;
        } else {
            merkleRoot = keccak256(abi.encodePacked(bobLeaf, aliceLeaf));
            aliceProof[0] = bobLeaf;
            bobProof[0] = aliceLeaf;
        }
    }

    function _initDividend(
        bytes32 _intentId,
        uint256 totalAmt,
        uint256 deadline,
        bool withholding,
        uint256 withholdingBps
    ) internal {
        bytes memory actionParams = abi.encode(
            address(usdc), totalAmt, 250_000, merkleRoot,
            block.number, deadline, withholding, withholdingBps
        );

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: _intentId,
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(stockToken),
            ticker: "AAPL",
            isin: "US0378331005",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: actionParams,
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        distributor.execute(intent);
    }

    function test_executeInitialization() public {
        _initDividend(intentId, 87_500_000, block.timestamp + 90 days, false, 0);

        (,, uint256 totalClaimed, bool initialized,) = _getDividendState(intentId);
        assertTrue(initialized);
        assertEq(totalClaimed, 0);
    }

    function test_claimWithValidProof() public {
        _initDividend(intentId, 87_500_000, block.timestamp + 90 days, false, 0);

        vm.prank(alice);
        distributor.claimDividend(intentId, aliceAmount, aliceProof);
        assertEq(usdc.balanceOf(alice), aliceAmount);
    }

    function test_withholdingTaxApplication() public {
        uint256 withholdingBps = 3000; // 30%
        _initDividend(intentId, 87_500_000, block.timestamp + 90 days, true, withholdingBps);

        vm.prank(alice);
        distributor.claimDividend(intentId, aliceAmount, aliceProof);

        uint256 withheld = (aliceAmount * withholdingBps) / 10000;
        uint256 netAmount = aliceAmount - withheld;

        assertEq(usdc.balanceOf(alice), netAmount);
        assertEq(usdc.balanceOf(treasury), withheld);
    }

    function test_revert_doubleClaim() public {
        _initDividend(intentId, 87_500_000, block.timestamp + 90 days, false, 0);

        vm.prank(alice);
        distributor.claimDividend(intentId, aliceAmount, aliceProof);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            DividendDistributor.AlreadyClaimed.selector, intentId, alice
        ));
        distributor.claimDividend(intentId, aliceAmount, aliceProof);
    }

    function test_revert_expiredClaim() public {
        uint256 deadline = block.timestamp + 90 days;
        _initDividend(intentId, 87_500_000, deadline, false, 0);

        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            DividendDistributor.ClaimPeriodExpired.selector, intentId
        ));
        distributor.claimDividend(intentId, aliceAmount, aliceProof);
    }

    function test_reclaimExpiredFunds() public {
        uint256 deadline = block.timestamp + 90 days;
        _initDividend(intentId, 87_500_000, deadline, false, 0);

        // Alice claims, Bob does not
        vm.prank(alice);
        distributor.claimDividend(intentId, aliceAmount, aliceProof);

        vm.warp(deadline + 1);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        distributor.reclaimExpired(intentId);

        uint256 remaining = 87_500_000 - aliceAmount;
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, remaining);
    }

    function test_revert_reclaimBeforeDeadline() public {
        uint256 deadline = block.timestamp + 90 days;
        _initDividend(intentId, 87_500_000, deadline, false, 0);

        vm.expectRevert(abi.encodeWithSelector(
            DividendDistributor.ClaimPeriodActive.selector, intentId
        ));
        distributor.reclaimExpired(intentId);
    }

    function _getDividendState(bytes32 id) internal view
        returns (DividendDistributor.DividendParams memory, uint256, uint256, bool, bool)
    {
        // Read fields individually from the public mapping
        (,,uint256 totalClaimed, bool initialized, bool fundsReclaimed) =
            distributor.dividends(id);
        DividendDistributor.DividendParams memory params;
        return (params, 0, totalClaimed, initialized, fundsReclaimed);
    }
}
