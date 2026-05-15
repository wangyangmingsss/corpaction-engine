// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpinoffExecutor} from "../../src/executors/SpinoffExecutor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SpinoffExecutorTest is Test {
    SpinoffExecutor public executor;
    MockERC20 public parentToken;
    MockERC20 public newToken;

    address public registry = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public aliceAmount = 25e18;
    bytes32 public merkleRoot;
    bytes32[] public aliceProof;

    function setUp() public {
        parentToken = new MockERC20("AT&T", "T", 18);
        newToken = new MockERC20("WBD", "WBD", 18);

        SpinoffExecutor impl = new SpinoffExecutor();
        bytes memory initData = abi.encodeWithSelector(
            SpinoffExecutor.initialize.selector, registry
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        executor = SpinoffExecutor(address(proxy));

        newToken.mint(address(executor), 1_000_000e18);

        // Single-leaf merkle for alice
        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        merkleRoot = aliceLeaf;
        aliceProof = new bytes32[](0);
    }

    function _buildSpinoffIntent(bytes32 intentId, uint256 deadline)
        internal view returns (ICorpActionTypes.ActionIntent memory)
    {
        SpinoffExecutor.SpinoffParams memory params = SpinoffExecutor.SpinoffParams({
            newToken: address(newToken),
            distributionRatioNum: 1,
            distributionRatioDen: 4,
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: deadline
        });

        return ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.SPINOFF,
            targetToken: address(parentToken),
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
    }

    function test_executeInitialization() public {
        bytes32 intentId = keccak256("spinoff-1");
        executor.execute(_buildSpinoffIntent(intentId, block.timestamp + 90 days));

        (,bool initialized,) = executor.spinoffs(intentId);
        assertTrue(initialized);
    }

    function test_claimSpinoffTokens() public {
        bytes32 intentId = keccak256("spinoff-claim");
        executor.execute(_buildSpinoffIntent(intentId, block.timestamp + 90 days));

        vm.prank(alice);
        executor.claimSpinoff(intentId, aliceAmount, aliceProof);
        assertEq(newToken.balanceOf(alice), aliceAmount);
    }

    function test_revert_invalidProof() public {
        bytes32 intentId = keccak256("spinoff-bad-proof");
        executor.execute(_buildSpinoffIntent(intentId, block.timestamp + 90 days));

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("garbage");

        vm.prank(alice);
        vm.expectRevert(SpinoffExecutor.InvalidMerkleProof.selector);
        executor.claimSpinoff(intentId, aliceAmount, badProof);
    }

    function test_revert_afterDeadline() public {
        bytes32 intentId = keccak256("spinoff-expired");
        uint256 deadline = block.timestamp + 90 days;
        executor.execute(_buildSpinoffIntent(intentId, deadline));

        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            SpinoffExecutor.ClaimExpired.selector, intentId
        ));
        executor.claimSpinoff(intentId, aliceAmount, aliceProof);
    }

    function test_revert_doubleClaim() public {
        bytes32 intentId = keccak256("spinoff-double");
        executor.execute(_buildSpinoffIntent(intentId, block.timestamp + 90 days));

        vm.prank(alice);
        executor.claimSpinoff(intentId, aliceAmount, aliceProof);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            SpinoffExecutor.AlreadyClaimed.selector, intentId, alice
        ));
        executor.claimSpinoff(intentId, aliceAmount, aliceProof);
    }

    function test_revert_notInitialized() public {
        bytes32 intentId = keccak256("spinoff-missing");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            SpinoffExecutor.NotInitialized.selector, intentId
        ));
        executor.claimSpinoff(intentId, aliceAmount, aliceProof);
    }
}
