// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinoffExecutor} from "../../src/executors/SpinoffExecutor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title AT&T / Warner Bros Discovery Spin-off
/// @notice Simulates the AT&T spin-off of WarnerMedia into Warner Bros. Discovery
///         AT&T shareholders received 0.241917 shares of WBD per AT&T share
contract ATT_WBD_SpinoffTest is Test {
    SpinoffExecutor public executor;
    MockERC20 public attToken;
    MockERC20 public wbdToken;

    address public registry = address(this);

    address public retailHolder = makeAddr("retailHolder");
    address public pensionFund = makeAddr("pensionFund");
    address public hedgeFund = makeAddr("hedgeFund");

    // Distribution ratio: ~0.241917 WBD per T share
    // Approximated as 241917 / 1000000
    uint256 constant RATIO_NUM = 241917;
    uint256 constant RATIO_DEN = 1000000;

    uint256 constant RETAIL_ATT = 200e18;     // 200 AT&T shares
    uint256 constant PENSION_ATT = 500_000e18;
    uint256 constant HEDGE_ATT = 1_000_000e18;

    // WBD entitlements (shares * ratio)
    uint256 constant RETAIL_WBD = (200e18 * RATIO_NUM) / RATIO_DEN;
    uint256 constant PENSION_WBD = (500_000e18 * RATIO_NUM) / RATIO_DEN;
    uint256 constant HEDGE_WBD = (1_000_000e18 * RATIO_NUM) / RATIO_DEN;

    bytes32 public merkleRoot;
    bytes32[] public retailProof;
    bytes32[] public pensionProof;
    bytes32[] public hedgeProof;

    function setUp() public {
        attToken = new MockERC20("AT&T Inc.", "T", 18);
        wbdToken = new MockERC20("Warner Bros. Discovery", "WBD", 18);

        SpinoffExecutor impl = new SpinoffExecutor();
        bytes memory initData = abi.encodeWithSelector(
            SpinoffExecutor.initialize.selector, registry
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        executor = SpinoffExecutor(address(proxy));

        // Fund executor with WBD tokens
        wbdToken.mint(address(executor), 500_000_000e18);

        attToken.mint(retailHolder, RETAIL_ATT);
        attToken.mint(pensionFund, PENSION_ATT);
        attToken.mint(hedgeFund, HEDGE_ATT);

        // Build merkle tree with WBD entitlements
        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(retailHolder, RETAIL_WBD))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(pensionFund, PENSION_WBD))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(hedgeFund, HEDGE_WBD))));

        bytes32 pair01 = leaf0 <= leaf1
            ? keccak256(abi.encodePacked(leaf0, leaf1))
            : keccak256(abi.encodePacked(leaf1, leaf0));

        merkleRoot = pair01 <= leaf2
            ? keccak256(abi.encodePacked(pair01, leaf2))
            : keccak256(abi.encodePacked(leaf2, pair01));

        retailProof = new bytes32[](2);
        retailProof[0] = leaf1;
        retailProof[1] = leaf2;

        pensionProof = new bytes32[](2);
        pensionProof[0] = leaf0;
        pensionProof[1] = leaf2;

        hedgeProof = new bytes32[](1);
        hedgeProof[0] = pair01;
    }

    function test_attWbdSpinoff() public {
        bytes32 intentId = keccak256("att-wbd-spinoff-2022");

        SpinoffExecutor.SpinoffParams memory params = SpinoffExecutor.SpinoffParams({
            newToken: address(wbdToken),
            distributionRatioNum: RATIO_NUM,
            distributionRatioDen: RATIO_DEN,
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: block.timestamp + 90 days
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.SPINOFF,
            targetToken: address(attToken),
            ticker: "T",
            isin: "US00206R1023",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("sec-att-spinoff-8k"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        bytes memory result = executor.execute(intent);
        (address newToken, uint256 ratioNum, uint256 ratioDen) =
            abi.decode(result, (address, uint256, uint256));

        assertEq(newToken, address(wbdToken));
        assertEq(ratioNum, RATIO_NUM);
        assertEq(ratioDen, RATIO_DEN);

        // Retail holder claims: 200 * 0.241917 = ~48.3834 WBD
        vm.prank(retailHolder);
        executor.claimSpinoff(intentId, RETAIL_WBD, retailProof);
        assertEq(wbdToken.balanceOf(retailHolder), RETAIL_WBD);
        assertGt(RETAIL_WBD, 0);

        // Pension fund claims
        vm.prank(pensionFund);
        executor.claimSpinoff(intentId, PENSION_WBD, pensionProof);
        assertEq(wbdToken.balanceOf(pensionFund), PENSION_WBD);

        // Hedge fund claims
        vm.prank(hedgeFund);
        executor.claimSpinoff(intentId, HEDGE_WBD, hedgeProof);
        assertEq(wbdToken.balanceOf(hedgeFund), HEDGE_WBD);

        // AT&T balances remain unchanged (spinoff doesn't affect parent token)
        assertEq(attToken.balanceOf(retailHolder), RETAIL_ATT);
        assertEq(attToken.balanceOf(pensionFund), PENSION_ATT);
        assertEq(attToken.balanceOf(hedgeFund), HEDGE_ATT);
    }

    function test_attWbdSpinoff_doubleClaim() public {
        bytes32 intentId = keccak256("att-wbd-double");

        SpinoffExecutor.SpinoffParams memory params = SpinoffExecutor.SpinoffParams({
            newToken: address(wbdToken),
            distributionRatioNum: RATIO_NUM,
            distributionRatioDen: RATIO_DEN,
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: block.timestamp + 90 days
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.SPINOFF,
            targetToken: address(attToken),
            ticker: "T",
            isin: "US00206R1023",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        executor.execute(intent);

        vm.prank(retailHolder);
        executor.claimSpinoff(intentId, RETAIL_WBD, retailProof);

        vm.prank(retailHolder);
        vm.expectRevert(abi.encodeWithSelector(
            SpinoffExecutor.AlreadyClaimed.selector, intentId, retailHolder
        ));
        executor.claimSpinoff(intentId, RETAIL_WBD, retailProof);
    }
}
