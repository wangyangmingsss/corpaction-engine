// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {DelistingManager} from "../../src/executors/DelistingManager.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DelistingFlowTest is Test {
    ActionRegistry registry;
    DelistingManager delistMgr;
    MockValidatorManager validators;
    MockERC20 stockToken;
    MockERC20 usdc;

    address[] validatorAddrs;
    uint256[] validatorKeys;
    address alice = makeAddr("alice");

    uint256 aliceAmount = 5420e6; // 100 shares * $54.20

    bytes32 merkleRoot;
    bytes32[] aliceProof;

    function setUp() public {
        stockToken = new MockERC20("TWTR", "TWTR", 18);
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
        validators.setQuorumForType(ICorpActionTypes.ActionType.DELISTING, 2);
        validators.setSuperMaj(4);

        ActionRegistry regImpl = new ActionRegistry();
        bytes memory regInit = abi.encodeWithSelector(
            ActionRegistry.initialize.selector, address(validators), 7 days
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = ActionRegistry(address(regProxy));

        DelistingManager delistImpl = new DelistingManager();
        bytes memory delistInit = abi.encodeWithSelector(
            DelistingManager.initialize.selector, address(registry), address(0xBEEF)
        );
        ERC1967Proxy delistProxy = new ERC1967Proxy(address(delistImpl), delistInit);
        delistMgr = DelistingManager(address(delistProxy));

        registry.registerExecutor(ICorpActionTypes.ActionType.DELISTING, address(delistMgr));
        registry.setTimelock(ICorpActionTypes.ActionType.DELISTING, 0);

        usdc.mint(address(delistMgr), 10_000_000e6);

        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        merkleRoot = aliceLeaf;
        aliceProof = new bytes32[](0);
    }

    function test_full5PhaseDelisting() public {
        bytes32 intentId = keccak256("twtr-delisting");

        uint256 sellOnlyTime = block.timestamp + 48 hours;
        uint256 priceLockTime = block.timestamp + 72 hours;

        DelistingManager.DelistingParams memory delistParams = DelistingManager.DelistingParams({
            announcementTime: block.timestamp,
            sellOnlyTime: sellOnlyTime,
            priceLockTime: priceLockTime,
            finalPrice: 54_200_000,
            settlementToken: address(usdc),
            merkleRoot: merkleRoot,
            totalPool: 5_000_000e6,
            claimDeadline: block.timestamp + 180 days
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DELISTING,
            targetToken: address(stockToken),
            ticker: "TWTR",
            isin: "US90184L1026",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(delistParams),
            sourceAttestation: keccak256("sec-twtr-delist"),
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

        // Queue & Execute
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(intentId);
        }
        registry.executeAction(intentId);

        // Phase 1: ANNOUNCED
        (, DelistingManager.DelistingPhase phase,,,,,) = delistMgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.ANNOUNCED));

        // Phase 2: SELL_ONLY
        vm.warp(sellOnlyTime);
        delistMgr.advancePhase(intentId);
        (, phase,,,,,) = delistMgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.SELL_ONLY));

        // Phase 3: PRICE_LOCKED
        vm.warp(priceLockTime);
        delistMgr.advancePhase(intentId);
        (, phase,,,,,) = delistMgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.PRICE_LOCKED));

        // Phase 4: LIQUIDATING
        delistMgr.advancePhase(intentId);
        (, phase,,,,,) = delistMgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.LIQUIDATING));

        // Alice claims liquidation
        vm.prank(alice);
        delistMgr.claimLiquidation(intentId, aliceAmount, aliceProof);
        assertEq(usdc.balanceOf(alice), aliceAmount);

        // Phase 5: FROZEN
        delistMgr.freezeToken(intentId);
        (, phase,,,,,) = delistMgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.FROZEN));
    }
}
