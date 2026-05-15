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
}
