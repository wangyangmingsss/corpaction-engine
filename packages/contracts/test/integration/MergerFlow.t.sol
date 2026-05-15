// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {MergerHandler} from "../../src/executors/MergerHandler.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MergerFlowTest is Test {
    ActionRegistry registry;
    MergerHandler handler;
    MockValidatorManager validators;
    MockERC20 sourceToken;
    MockERC20 acquiringToken;

    address[] validatorAddrs;
    uint256[] validatorKeys;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 aliceShares = 100e18;
    uint256 bobShares = 250e18;

    bytes32 merkleRoot;
    bytes32[] aliceProof;
    bytes32[] bobProof;

    function setUp() public {
        sourceToken = new MockERC20("Source Corp", "SRC", 18);
        acquiringToken = new MockERC20("Acquiring Corp", "ACQ", 18);

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
        validators.setQuorumForType(ICorpActionTypes.ActionType.MERGER_STOCK, 2);
        validators.setSuperMaj(4);

        ActionRegistry regImpl = new ActionRegistry();
        bytes memory regInit = abi.encodeWithSelector(
            ActionRegistry.initialize.selector, address(validators), 7 days
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = ActionRegistry(address(regProxy));

        MergerHandler mergerImpl = new MergerHandler();
        bytes memory mergerInit = abi.encodeWithSelector(
            MergerHandler.initialize.selector, address(registry)
        );
        ERC1967Proxy mergerProxy = new ERC1967Proxy(address(mergerImpl), mergerInit);
        handler = MergerHandler(address(mergerProxy));

        registry.registerExecutor(ICorpActionTypes.ActionType.MERGER_STOCK, address(handler));
        registry.setTimelock(ICorpActionTypes.ActionType.MERGER_STOCK, 0);

        acquiringToken.mint(address(handler), 1_000_000e18);
        sourceToken.mint(alice, aliceShares);
        sourceToken.mint(bob, bobShares);

        // Build merkle
        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceShares))));
        bytes32 bobLeaf = keccak256(bytes.concat(keccak256(abi.encode(bob, bobShares))));

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

    function test_fullStockForStockMerger() public {
        bytes32 intentId = keccak256("merger-sfs-flow");

        MergerHandler.MergerParams memory mergerParams = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.STOCK_FOR_STOCK,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 3,
            exchangeRatioDen: 2,
            cashPerShare: 0,
            cashToken: address(0),
            electionDeadline: 0,
            hasElection: false,
            prorationFactor: 10000,
            merkleRoot: merkleRoot,
            totalCashPool: 0
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.MERGER_STOCK,
            targetToken: address(sourceToken),
            ticker: "SRC",
            isin: "US0000000000",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(mergerParams),
            sourceAttestation: keccak256("sec-merger-filing"),
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

        // Queue
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        if (stored.state == ICorpActionTypes.ActionState.VALIDATED) {
            registry.queueAction(intentId);
        }

        // Execute
        registry.executeAction(intentId);

        stored = registry.getAction(intentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.EXECUTED));

        // Alice claims: 100 shares * 3/2 = 150 acquiring tokens
        vm.prank(alice);
        handler.claimMerger(intentId, aliceShares, aliceProof);
        assertEq(acquiringToken.balanceOf(alice), 150e18);

        // Bob claims: 250 shares * 3/2 = 375 acquiring tokens
        vm.prank(bob);
        handler.claimMerger(intentId, bobShares, bobProof);
        assertEq(acquiringToken.balanceOf(bob), 375e18);
    }
}
