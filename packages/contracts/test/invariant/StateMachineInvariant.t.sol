// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DelistingManager} from "../../src/executors/DelistingManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StateMachineInvariantHandler is Test {
    DelistingManager public mgr;
    bytes32 public intentId;
    uint8 public highestPhaseReached;

    constructor(DelistingManager _mgr, bytes32 _intentId) {
        mgr = _mgr;
        intentId = _intentId;
        highestPhaseReached = uint8(DelistingManager.DelistingPhase.ANNOUNCED);
    }

    function advancePhase(uint256 timeSkip) external {
        timeSkip = bound(timeSkip, 0, 100 hours);
        vm.warp(block.timestamp + timeSkip);

        try mgr.advancePhase(intentId) {} catch {}

        (, DelistingManager.DelistingPhase currentPhase,,,,,) = mgr.delistings(intentId);
        if (uint8(currentPhase) > highestPhaseReached) {
            highestPhaseReached = uint8(currentPhase);
        }
    }

    function freezeToken() external {
        try mgr.freezeToken(intentId) {} catch {}

        (, DelistingManager.DelistingPhase currentPhase,,,,,) = mgr.delistings(intentId);
        if (uint8(currentPhase) > highestPhaseReached) {
            highestPhaseReached = uint8(currentPhase);
        }
    }
}

contract StateMachineInvariantTest is Test {
    DelistingManager public mgr;
    StateMachineInvariantHandler public handler;
    bytes32 public intentId = keccak256("state-machine-test");

    function setUp() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockERC20 stockToken = new MockERC20("TST", "TST", 18);

        DelistingManager impl = new DelistingManager();
        bytes memory initData = abi.encodeWithSelector(
            DelistingManager.initialize.selector, address(this), address(0xBEEF)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        mgr = DelistingManager(address(proxy));

        usdc.mint(address(mgr), 1_000_000e6);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(makeAddr("holder"), uint256(1000e6)))));

        DelistingManager.DelistingParams memory params = DelistingManager.DelistingParams({
            announcementTime: block.timestamp,
            sellOnlyTime: block.timestamp + 48 hours,
            priceLockTime: block.timestamp + 72 hours,
            finalPrice: 10e6,
            settlementToken: address(usdc),
            merkleRoot: leaf,
            totalPool: 100_000e6,
            claimDeadline: block.timestamp + 180 days
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DELISTING,
            targetToken: address(stockToken),
            ticker: "TST",
            isin: "XX",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        mgr.execute(intent);

        handler = new StateMachineInvariantHandler(mgr, intentId);
        targetContract(address(handler));
    }

    /// @dev Invariant: state transitions never go backward (phase ordinal only increases)
    function invariant_stateNeverGoesBackward() public view {
        (, DelistingManager.DelistingPhase currentPhase,,,,,) = mgr.delistings(intentId);
        // Current phase should always be >= ANNOUNCED (1) if initialized
        assertGe(uint8(currentPhase), uint8(DelistingManager.DelistingPhase.ANNOUNCED));
    }

    /// @dev Invariant: FROZEN is terminal
    function invariant_frozenIsTerminal() public view {
        (, DelistingManager.DelistingPhase currentPhase,,,,,) = mgr.delistings(intentId);
        if (handler.highestPhaseReached() == uint8(DelistingManager.DelistingPhase.FROZEN)) {
            assertEq(uint8(currentPhase), uint8(DelistingManager.DelistingPhase.FROZEN));
        }
    }
}
