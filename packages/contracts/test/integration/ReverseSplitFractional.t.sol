// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {SplitExecutor} from "../../src/executors/SplitExecutor.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC8056} from "../mocks/MockERC8056.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ReverseSplitFractionalTest is Test {
    ActionRegistry registry;
    SplitExecutor executor;
    MockValidatorManager validators;
    MockERC8056 stockToken;
    MockERC20 usdc;

    address[] validatorAddrs;
    uint256[] validatorKeys;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        stockToken = new MockERC8056("Test Token", "TST", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

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
        validators.setQuorumForType(ICorpActionTypes.ActionType.REVERSE_SPLIT, 2);
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

        registry.registerExecutor(ICorpActionTypes.ActionType.REVERSE_SPLIT, address(executor));
        registry.setTimelock(ICorpActionTypes.ActionType.REVERSE_SPLIT, 0);

        stockToken.mint(alice, 105e18);
        stockToken.mint(bob, 250e18);

        usdc.mint(address(executor), 100_000e6);
    }

    function test_reverseSplitWithCashInLieu() public {
        bytes32 intentId = keccak256("reverse-split-cil");

        SplitExecutor.SplitParams memory splitParams = SplitExecutor.SplitParams({
            numerator: 10,
            denominator: 1,
            isReverse: true,
            expectedNewMultiplier: 0.1e18,
            fractionalHandling: 2,
            cashInLieuToken: address(usdc),
            cashInLieuPrice: 50e6 // $50 per fractional share
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.REVERSE_SPLIT,
            targetToken: address(stockToken),
            ticker: "TST",
            isin: "US0000000000",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(splitParams),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        // Propose
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validatorKeys[0],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );
        registry.proposeAction(intent, abi.encodePacked(r, s, v));

        // Validate
        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(
            validatorKeys[1],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash))
        );
        registry.validateAction(intentId, abi.encodePacked(r, s, v));

        // Queue if needed
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(intentId);
        }

        // Execute
        registry.executeAction(intentId);

        // Verify split executed
        assertEq(stockToken.uiMultiplier(), 0.1e18);

        // Verify cash-in-lieu was initialized
        (address cashToken, uint256 price,,, bool initialized) =
            executor.cashInLieu(intentId);
        assertTrue(initialized);
        assertEq(cashToken, address(usdc));
        assertEq(price, 50e6);

        // Set merkle root for fractional shares
        // Alice had 105 shares, 1:10 reverse -> 10.5 shares UI -> 0.5 fractional
        uint256 aliceFractional = 0.5e18;
        bytes32 leaf = keccak256(abi.encodePacked(alice, aliceFractional));
        bytes32 merkleRoot = leaf;

        executor.setCashInLieuMerkle(intentId, merkleRoot, block.timestamp + 90 days);

        // Alice claims cash-in-lieu for fractional shares
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        executor.claimCashInLieu(intentId, aliceFractional, proof);

        uint256 expectedPayout = (aliceFractional * 50e6) / 1e18;
        assertEq(usdc.balanceOf(alice), expectedPayout);
    }
}
