// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {SplitExecutor} from "../../src/executors/SplitExecutor.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC8056} from "../mocks/MockERC8056.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StockSplitTest is Test {
    ActionRegistry registry;
    SplitExecutor executor;
    MockValidatorManager validators;
    MockERC8056 stockToken;

    address[] validatorAddrs;
    uint256[] validatorKeys;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        stockToken = new MockERC8056("NVDA Token", "NVDA", 18);

        for (uint i = 0; i < 5; i++) {
            (address addr, uint256 key) = makeAddrAndKey(
                string(abi.encodePacked("validator", vm.toString(i)))
            );
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }

        validators = new MockValidatorManager();
        for (uint i = 0; i < 5; i++) {
            validators.addValidator(validatorAddrs[i]);
        }
        validators.setQuorumForType(ICorpActionTypes.ActionType.FORWARD_SPLIT, 2);
        validators.setSuperMaj(4);

        ActionRegistry regImpl = new ActionRegistry();
        bytes memory regInit = abi.encodeWithSelector(
            ActionRegistry.initialize.selector, address(validators), 7 days
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = ActionRegistry(address(regProxy));

        SplitExecutor splitImpl = new SplitExecutor();
        bytes memory splitInit = abi.encodeWithSelector(
            SplitExecutor.initialize.selector, address(registry)
        );
        ERC1967Proxy splitProxy = new ERC1967Proxy(address(splitImpl), splitInit);
        executor = SplitExecutor(address(splitProxy));

        registry.registerExecutor(ICorpActionTypes.ActionType.FORWARD_SPLIT, address(executor));
        registry.setTimelock(ICorpActionTypes.ActionType.FORWARD_SPLIT, 0);

        stockToken.mint(alice, 100e18);
        stockToken.mint(bob, 250e18);
    }

    function test_fullForwardSplit_4to1() public {
        SplitExecutor.SplitParams memory splitParams = SplitExecutor.SplitParams({
            numerator: 4,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 4e18,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        bytes32 intentId = keccak256("nvda-split-4to1");

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.FORWARD_SPLIT,
            targetToken: address(stockToken),
            ticker: "NVDA",
            isin: "US67066G1040",
            recordDate: block.timestamp + 1 days,
            exDate: block.timestamp + 2 days,
            effectiveDate: block.timestamp + 3 days,
            actionParams: abi.encode(splitParams),
            sourceAttestation: keccak256("sec-edgar-nvda"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        // Step 1: Propose
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validatorKeys[0],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );
        registry.proposeAction(intent, abi.encodePacked(r, s, v));

        // Step 2: Validate (reaches quorum of 2)
        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(
            validatorKeys[1],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash))
        );
        registry.validateAction(intentId, abi.encodePacked(r, s, v));

        // Verify QUEUED state (quorum reached -> VALIDATED, then auto-queue depends on impl)
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        // After quorum, state should be VALIDATED
        // Need to queue explicitly if the implementation requires it
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(intentId);
        }

        // Step 3: Execute
        registry.executeAction(intentId);

        // Step 4: Verify
        stored = registry.getAction(intentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.EXECUTED));

        // Verify multiplier = 4x
        assertEq(stockToken.uiMultiplier(), 4e18);

        // Verify balanceOfUI
        assertEq(stockToken.balanceOfUI(alice), 400e18); // 100 * 4
        assertEq(stockToken.balanceOfUI(bob), 1000e18);  // 250 * 4

        // Raw balances unchanged
        assertEq(stockToken.balanceOf(alice), 100e18);
        assertEq(stockToken.balanceOf(bob), 250e18);
    }
}
