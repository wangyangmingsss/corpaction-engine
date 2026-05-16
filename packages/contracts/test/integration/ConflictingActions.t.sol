// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {SplitExecutor} from "../../src/executors/SplitExecutor.sol";
import {DelistingManager} from "../../src/executors/DelistingManager.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC8056} from "../mocks/MockERC8056.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ConflictingActionsTest is Test {
    ActionRegistry registry;
    SplitExecutor splitExecutor;
    DelistingManager delistMgr;
    MockValidatorManager validators;
    MockERC8056 stockToken;
    MockERC20 usdc;

    address[] validatorAddrs;
    uint256[] validatorKeys;

    function setUp() public {
        stockToken = new MockERC8056("Conflict Token", "CFT", 18);
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
        validators.setQuorumForType(ICorpActionTypes.ActionType.FORWARD_SPLIT, 2);
        validators.setQuorumForType(ICorpActionTypes.ActionType.DELISTING, 2);
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
        splitExecutor = SplitExecutor(address(splitProxy));

        DelistingManager delistImpl = new DelistingManager();
        bytes memory delistInit = abi.encodeWithSelector(
            DelistingManager.initialize.selector, address(registry), address(0xBEEF)
        );
        ERC1967Proxy delistProxy = new ERC1967Proxy(address(delistImpl), delistInit);
        delistMgr = DelistingManager(address(delistProxy));

        registry.registerExecutor(ICorpActionTypes.ActionType.FORWARD_SPLIT, address(splitExecutor));
        registry.registerExecutor(ICorpActionTypes.ActionType.DELISTING, address(delistMgr));
        registry.setTimelock(ICorpActionTypes.ActionType.FORWARD_SPLIT, 0);
        registry.setTimelock(ICorpActionTypes.ActionType.DELISTING, 0);

        usdc.mint(address(delistMgr), 1_000_000e6);
    }

    function _proposeAndQueue(
        ICorpActionTypes.ActionIntent memory intent
    ) internal returns (bytes32) {
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validatorKeys[0],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );
        registry.proposeAction(intent, abi.encodePacked(r, s, v));

        bytes32 valHash = keccak256(abi.encode(
            intent.intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(
            validatorKeys[1],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash))
        );
        registry.validateAction(intent.intentId, abi.encodePacked(r, s, v));

        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intent.intentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(intent.intentId);
        }

        return intent.intentId;
    }

    function test_sameTokenSplitAndDelisting() public {
        // Propose a split for CFT
        SplitExecutor.SplitParams memory splitParams = SplitExecutor.SplitParams({
            numerator: 2,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 2e18,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        bytes32 splitId = keccak256("cft-split");
        ICorpActionTypes.ActionIntent memory splitIntent = ICorpActionTypes.ActionIntent({
            intentId: splitId,
            actionType: ICorpActionTypes.ActionType.FORWARD_SPLIT,
            targetToken: address(stockToken),
            ticker: "CFT",
            isin: "XX",
            recordDate: block.timestamp + 1 days,
            exDate: block.timestamp + 2 days,
            effectiveDate: block.timestamp + 3 days,
            actionParams: abi.encode(splitParams),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        _proposeAndQueue(splitIntent);

        // Propose a delisting for the same token
        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(makeAddr("alice"), uint256(1000e6)))));
        DelistingManager.DelistingParams memory delistParams = DelistingManager.DelistingParams({
            announcementTime: block.timestamp,
            sellOnlyTime: block.timestamp + 48 hours,
            priceLockTime: block.timestamp + 72 hours,
            finalPrice: 10e6,
            settlementToken: address(usdc),
            merkleRoot: aliceLeaf,
            totalPool: 100_000e6,
            claimDeadline: block.timestamp + 180 days
        });

        bytes32 delistId = keccak256("cft-delist");
        ICorpActionTypes.ActionIntent memory delistIntent = ICorpActionTypes.ActionIntent({
            intentId: delistId,
            actionType: ICorpActionTypes.ActionType.DELISTING,
            targetToken: address(stockToken),
            ticker: "CFT",
            isin: "XX",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(delistParams),
            sourceAttestation: keccak256("test2"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        _proposeAndQueue(delistIntent);

        // Both actions are queued for the same token
        bytes32[] memory actions = registry.getActionsByToken(address(stockToken));
        assertEq(actions.length, 2);

        // Execute split first
        registry.executeAction(splitId);
        ICorpActionTypes.ActionIntent memory splitStored = registry.getAction(splitId);
        assertEq(uint8(splitStored.state), uint8(ICorpActionTypes.ActionState.EXECUTED));

        // Cancel delisting since split changed conditions
        vm.prank(validatorAddrs[0]);
        registry.cancelAction(delistId, "Split executed, conditions changed");

        ICorpActionTypes.ActionIntent memory delistStored = registry.getAction(delistId);
        assertEq(uint8(delistStored.state), uint8(ICorpActionTypes.ActionState.CANCELLED));
    }
}
