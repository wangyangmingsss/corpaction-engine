// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {DividendDistributor} from "../../src/executors/DividendDistributor.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DividendFlowTest is Test {
    ActionRegistry registry;
    DividendDistributor distributor;
    MockValidatorManager validators;
    MockERC20 usdc;
    MockERC20 stockToken;

    address[] validatorAddrs;
    uint256[] validatorKeys;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        stockToken = new MockERC20("AAPL Token", "AAPL", 18);

        // Setup validators
        for (uint i = 0; i < 5; i++) {
            (address addr, uint256 key) = makeAddrAndKey(
                string(abi.encodePacked("validator", vm.toString(i)))
            );
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }

        // Deploy MockValidatorManager
        validators = new MockValidatorManager();
        for (uint i = 0; i < 5; i++) {
            validators.addValidator(validatorAddrs[i]);
        }
        validators.setQuorumForType(ICorpActionTypes.ActionType.DIVIDEND, 2);
        validators.setSuperMaj(4);

        // Deploy ActionRegistry via proxy
        ActionRegistry regImpl = new ActionRegistry();
        bytes memory regInit = abi.encodeWithSelector(
            ActionRegistry.initialize.selector,
            address(validators),
            7 days
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = ActionRegistry(address(regProxy));

        // Deploy DividendDistributor via proxy
        DividendDistributor divImpl = new DividendDistributor();
        bytes memory divInit = abi.encodeWithSelector(
            DividendDistributor.initialize.selector,
            address(registry),
            treasury
        );
        ERC1967Proxy divProxy = new ERC1967Proxy(address(divImpl), divInit);
        distributor = DividendDistributor(address(divProxy));

        // Register executor
        registry.registerExecutor(
            ICorpActionTypes.ActionType.DIVIDEND,
            address(distributor)
        );

        // Set timelock to 0 for testing
        registry.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 0);

        // Fund distributor with USDC for dividend pool
        usdc.mint(address(distributor), 10_000e6);

        // Give stock tokens to holders
        stockToken.mint(alice, 100e18);  // 100 shares
        stockToken.mint(bob, 250e18);    // 250 shares
    }

    function test_fullDividendFlow() public {
        // Build merkle tree for $0.25/share dividend
        // Alice: 100 shares * 0.25 = $25.00 = 25e6 USDC
        // Bob: 250 shares * 0.25 = $62.50 = 62.5e6 USDC
        uint256 aliceAmount = 25e6;
        uint256 bobAmount = 62_500_000; // 62.5 USDC

        // Compute leaves
        bytes32 aliceLeaf = keccak256(
            bytes.concat(keccak256(abi.encode(alice, aliceAmount)))
        );
        bytes32 bobLeaf = keccak256(
            bytes.concat(keccak256(abi.encode(bob, bobAmount)))
        );

        // Sort and compute root
        bytes32 merkleRoot;
        bytes32[] memory aliceProof = new bytes32[](1);
        bytes32[] memory bobProof = new bytes32[](1);

        if (aliceLeaf <= bobLeaf) {
            merkleRoot = keccak256(abi.encodePacked(aliceLeaf, bobLeaf));
            aliceProof[0] = bobLeaf;
            bobProof[0] = aliceLeaf;
        } else {
            merkleRoot = keccak256(abi.encodePacked(bobLeaf, aliceLeaf));
            aliceProof[0] = bobLeaf;
            bobProof[0] = aliceLeaf;
        }

        // Encode dividend params
        bytes memory actionParams = abi.encode(
            address(usdc),      // paymentToken
            87_500_000,         // totalAmount (87.5 USDC)
            250_000,            // amountPerShare (0.25 USDC)
            merkleRoot,
            block.number,       // snapshotBlock
            block.timestamp + 90 days, // claimDeadline
            false,              // withholding
            uint256(0)          // withholdingBps
        );

        bytes32 intentId = keccak256("dividend-aapl-q1-2026");

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(stockToken),
            ticker: "AAPL",
            isin: "US0378331005",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: actionParams,
            sourceAttestation: keccak256("sec-edgar-aapl-8k"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        // Propose with validator 0
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validatorKeys[0],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );
        bytes memory sig0 = abi.encodePacked(r, s, v);

        registry.proposeAction(intent, sig0);

        // Validate with validator 1 (reaches quorum of 2)
        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType,
            intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(
            validatorKeys[1],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash))
        );
        bytes memory sig1 = abi.encodePacked(r, s, v);

        registry.validateAction(intentId, sig1);

        // Execute
        registry.executeAction(intentId);

        // Verify executed
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.EXECUTED));

        // Alice claims
        vm.prank(alice);
        distributor.claimDividend(intentId, aliceAmount, aliceProof);
        assertEq(usdc.balanceOf(alice), aliceAmount);

        // Bob claims
        vm.prank(bob);
        distributor.claimDividend(intentId, bobAmount, bobProof);
        assertEq(usdc.balanceOf(bob), bobAmount);

        // Verify double-claim reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            DividendDistributor.AlreadyClaimed.selector, intentId, alice
        ));
        distributor.claimDividend(intentId, aliceAmount, aliceProof);
    }

    function test_reclaimExpiredDividends() public {
        // Setup a simple dividend with one holder
        uint256 aliceAmount = 25e6;
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(alice, aliceAmount)))
        );
        bytes32 merkleRoot = leaf; // Single leaf tree

        uint256 deadline = block.timestamp + 90 days;

        bytes memory actionParams = abi.encode(
            address(usdc), 25e6, 250_000, merkleRoot,
            block.number, deadline, false, uint256(0)
        );

        bytes32 intentId = keccak256("dividend-reclaim-test");

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(stockToken),
            ticker: "AAPL",
            isin: "US0378331005",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: actionParams,
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        // Propose + validate + execute
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validatorKeys[0],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );
        registry.proposeAction(intent, abi.encodePacked(r, s, v));

        bytes32 valHash = keccak256(abi.encode(
            intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(
            validatorKeys[1],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash))
        );
        registry.validateAction(intentId, abi.encodePacked(r, s, v));
        registry.executeAction(intentId);

        // Warp past deadline
        vm.warp(deadline + 1);

        // Reclaim
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        distributor.reclaimExpired(intentId);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 25e6);
    }
}
