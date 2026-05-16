// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ActionRegistryTest is Test {
    ActionRegistry public registry;
    MockValidatorManager public validatorMgr;
    MockERC20 public stockToken;

    address public admin = makeAddr("admin");
    uint256 public validator1Key;
    address public validator1;
    uint256 public validator2Key;
    address public validator2;
    uint256 public validator3Key;
    address public validator3;

    function setUp() public {
        (validator1, validator1Key) = makeAddrAndKey("validator1");
        (validator2, validator2Key) = makeAddrAndKey("validator2");
        (validator3, validator3Key) = makeAddrAndKey("validator3");

        validatorMgr = new MockValidatorManager();
        validatorMgr.addValidator(validator1);
        validatorMgr.addValidator(validator2);
        validatorMgr.addValidator(validator3);
        validatorMgr.setQuorumForType(ICorpActionTypes.ActionType.DIVIDEND, 2);
        validatorMgr.setSuperMaj(3);

        stockToken = new MockERC20("AAPL Token", "AAPL", 18);

        // Deploy via proxy
        ActionRegistry impl = new ActionRegistry();
        bytes memory initData = abi.encodeWithSelector(
            ActionRegistry.initialize.selector,
            address(validatorMgr),
            7 days // intentTTL
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = ActionRegistry(address(proxy));
    }

    function _buildDividendIntent() internal view returns (ICorpActionTypes.ActionIntent memory) {
        return ICorpActionTypes.ActionIntent({
            intentId: keccak256("test-dividend-1"),
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(stockToken),
            ticker: "AAPL",
            isin: "US0378331005",
            recordDate: block.timestamp + 1 days,
            exDate: block.timestamp + 2 days,
            effectiveDate: block.timestamp + 3 days,
            actionParams: abi.encode(uint256(100e6)),
            sourceAttestation: keccak256("source-1"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });
    }

    function test_proposeAction() public {
        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32 intentId = registry.proposeAction(intent, sig);
        assertEq(intentId, intent.intentId);

        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        assertEq(stored.ticker, "AAPL");
        assertEq(uint8(stored.actionType), uint8(ICorpActionTypes.ActionType.DIVIDEND));
    }

    function test_proposeAndValidate_reachesQuorum() public {
        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        // Propose
        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32 intentId = registry.proposeAction(intent, sig);

        // Validate with second validator (quorum = 2)
        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType,
            intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(validator2Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash)));
        sig = abi.encodePacked(r, s, v);

        registry.validateAction(intentId, sig);

        // Should be QUEUED now
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.QUEUED));
    }

    function test_revert_duplicateIntent() public {
        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes memory sig = abi.encodePacked(r, s, v);

        registry.proposeAction(intent, sig);

        // Try to propose again
        vm.expectRevert(abi.encodeWithSelector(
            ActionRegistry.DuplicateIntent.selector, intent.intentId
        ));
        registry.proposeAction(intent, sig);
    }

    function test_cancelAction() public {
        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32 intentId = registry.proposeAction(intent, sig);

        vm.prank(validator1);
        registry.cancelAction(intentId, "Test cancellation");

        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.CANCELLED));
    }

    function test_emergencyPause() public {
        vm.prank(validator1);
        registry.emergencyPause();
        assertTrue(registry.paused());
    }

    function test_getActionsByToken() public {
        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes memory sig = abi.encodePacked(r, s, v);

        registry.proposeAction(intent, sig);

        bytes32[] memory actions = registry.getActionsByToken(address(stockToken));
        assertEq(actions.length, 1);
    }

    function test_timelockExecutionTimeValidation() public {
        // Set a 1-day timelock for DIVIDEND
        registry.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 1 days);

        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        // Propose
        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes32 intentId = registry.proposeAction(intent, sig);

        // Validate to reach quorum
        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(validator2Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash)));
        sig = abi.encodePacked(r, s, v);
        registry.validateAction(intentId, sig);

        // Queue
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(intentId);
        }

        // Try to execute before timelock expires
        vm.expectRevert(abi.encodeWithSelector(
            ActionRegistry.TimelockNotExpired.selector,
            intentId,
            registry.getExecutionTime(intentId)
        ));
        registry.executeAction(intentId);

        // Warp past timelock and verify execution time is set correctly
        uint256 execTime = registry.getExecutionTime(intentId);
        assertGt(execTime, block.timestamp);
    }

    function test_intentTTLExpiry() public {
        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        // Propose
        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes32 intentId = registry.proposeAction(intent, sig);

        // Warp past the intentTTL (7 days)
        vm.warp(block.timestamp + 8 days);

        // Try to validate after TTL - should revert
        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(validator2Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash)));
        sig = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(
            ActionRegistry.IntentExpired.selector, intentId
        ));
        registry.validateAction(intentId, sig);

        // Expire the intent explicitly
        registry.expireAction(intentId);
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.EXPIRED));
    }

    function test_executorRouting() public {
        // Register an executor for DIVIDEND
        address dividendExecutor = makeAddr("dividendExecutor");
        registry.registerExecutor(ICorpActionTypes.ActionType.DIVIDEND, dividendExecutor);

        // Register another for FORWARD_SPLIT
        address splitExecutor = makeAddr("splitExecutor");
        registry.registerExecutor(ICorpActionTypes.ActionType.FORWARD_SPLIT, splitExecutor);

        // Verify routing by attempting to execute without timelock
        registry.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 0);

        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        // Propose + validate
        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes32 intentId = registry.proposeAction(intent, abi.encodePacked(r, s, v));

        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(validator2Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash)));
        registry.validateAction(intentId, abi.encodePacked(r, s, v));

        // Queue
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(intentId);
        }

        // Execute will call the dividendExecutor address, which will revert
        // since it's just an EOA. But this proves the routing worked.
        registry.executeAction(intentId);
        stored = registry.getAction(intentId);
        // Should be FAILED since the executor EOA can't handle the call
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.FAILED));
    }

    function test_revert_registerExecutor_notAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");
        vm.prank(nonAdmin);
        vm.expectRevert();
        registry.registerExecutor(
            ICorpActionTypes.ActionType.DIVIDEND,
            makeAddr("executor")
        );
    }

    function test_revert_setTimelock_notAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");
        vm.prank(nonAdmin);
        vm.expectRevert();
        registry.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 1 days);
    }

    function _proposeValidateQueueExecute() internal returns (bytes32 intentId) {
        // Register a mock executor so execution succeeds with FAILED state (EOA)
        address dividendExecutor = makeAddr("dividendExecutor");
        registry.registerExecutor(ICorpActionTypes.ActionType.DIVIDEND, dividendExecutor);
        registry.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 0);

        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        // Propose
        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        intentId = registry.proposeAction(intent, abi.encodePacked(r, s, v));

        // Validate to reach quorum
        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(validator2Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash)));
        registry.validateAction(intentId, abi.encodePacked(r, s, v));

        // Queue
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(intentId);
        }

        // Execute (will FAIL since executor is an EOA, which is fine for reversal tests)
        registry.executeAction(intentId);
    }

    function test_reverseAction() public {
        bytes32 intentId = _proposeValidateQueueExecute();

        // The action should be in FAILED state since executor is an EOA.
        // For reverseAction we need EXECUTED state, so we need a real executor.
        // Instead, let's build a fresh intent and mock EXECUTED state via a
        // contract that returns bytes from execute().

        // Use a different approach: deploy a minimal executor mock
        MockExecutor mockExec = new MockExecutor();
        registry.registerExecutor(ICorpActionTypes.ActionType.DIVIDEND, address(mockExec));

        // Build a new intent with a different ID
        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: keccak256("test-dividend-reverse"),
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(stockToken),
            ticker: "AAPL",
            isin: "US0378331005",
            recordDate: block.timestamp + 1 days,
            exDate: block.timestamp + 2 days,
            effectiveDate: block.timestamp + 3 days,
            actionParams: abi.encode(uint256(100e6)),
            sourceAttestation: keccak256("source-reverse"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        // Propose
        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes32 newIntentId = registry.proposeAction(intent, abi.encodePacked(r, s, v));

        // Validate
        bytes32 valHash = keccak256(abi.encode(
            newIntentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(validator2Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash)));
        registry.validateAction(newIntentId, abi.encodePacked(r, s, v));

        // Queue and execute
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(newIntentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(newIntentId);
        }
        registry.executeAction(newIntentId);

        // Verify EXECUTED state
        stored = registry.getAction(newIntentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.EXECUTED));

        // Build reverse signatures from all 3 validators
        string memory reason = "Erroneous corporate action";
        bytes32 reverseHash = keccak256(
            abi.encodePacked("REVERSE_ACTION", newIntentId, reason)
        );

        bytes[] memory sigs = new bytes[](3);
        (v, r, s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", reverseHash)));
        sigs[0] = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(validator2Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", reverseHash)));
        sigs[1] = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(validator3Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", reverseHash)));
        sigs[2] = abi.encodePacked(r, s, v);

        // Reverse the action
        registry.reverseAction(newIntentId, reason, sigs);

        // Verify REVERSED state
        stored = registry.getAction(newIntentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.REVERSED));
    }

    function test_revert_reverseAction_notExecuted() public {
        ICorpActionTypes.ActionIntent memory intent = _buildDividendIntent();

        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes32 newIntentId = registry.proposeAction(intent, abi.encodePacked(r, s, v));

        // Try to reverse a PROPOSED action (should fail)
        bytes[] memory sigs = new bytes[](0);
        vm.expectRevert(abi.encodeWithSelector(
            ActionRegistry.InvalidState.selector,
            newIntentId,
            ICorpActionTypes.ActionState.PROPOSED,
            ICorpActionTypes.ActionState.EXECUTED
        ));
        registry.reverseAction(newIntentId, "bad", sigs);
    }

    function test_revert_reverseAction_insufficientSignatures() public {
        MockExecutor mockExec = new MockExecutor();
        registry.registerExecutor(ICorpActionTypes.ActionType.DIVIDEND, address(mockExec));
        registry.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 0);

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: keccak256("test-dividend-insuf-reverse"),
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(stockToken),
            ticker: "AAPL",
            isin: "US0378331005",
            recordDate: block.timestamp + 1 days,
            exDate: block.timestamp + 2 days,
            effectiveDate: block.timestamp + 3 days,
            actionParams: abi.encode(uint256(100e6)),
            sourceAttestation: keccak256("source-insuf"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        bytes32 hash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        bytes32 newIntentId = registry.proposeAction(intent, abi.encodePacked(r, s, v));

        bytes32 valHash = keccak256(abi.encode(
            newIntentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(validator2Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash)));
        registry.validateAction(newIntentId, abi.encodePacked(r, s, v));

        ICorpActionTypes.ActionIntent memory stored = registry.getAction(newIntentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(newIntentId);
        }
        registry.executeAction(newIntentId);

        // Only provide 1 signature (need 3)
        string memory reason = "Insufficient sigs test";
        bytes32 reverseHash = keccak256(
            abi.encodePacked("REVERSE_ACTION", newIntentId, reason)
        );
        bytes[] memory sigs = new bytes[](1);
        (v, r, s) = vm.sign(validator1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", reverseHash)));
        sigs[0] = abi.encodePacked(r, s, v);

        vm.expectRevert(); // Need all validator signatures
        registry.reverseAction(newIntentId, reason, sigs);
    }
}

/// @dev Minimal mock executor that returns empty bytes on execute
contract MockExecutor is ICorpActionTypes {
    function execute(ICorpActionTypes.ActionIntent calldata) external pure returns (bytes memory) {
        return "";
    }
}
