// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CrossChainNotifier} from "../../src/integrations/CrossChainNotifier.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingReceipt,
    MessagingFee
} from "../../src/interfaces/ILayerZero.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";

/// @notice Mock LayerZero V2 endpoint for testing
contract MockLzEndpoint is ILayerZeroEndpointV2 {
    uint256 public sendCallCount;
    MessagingParams public lastParams;
    uint256 public feePerMessage = 0.001 ether;

    function send(MessagingParams calldata _params, address)
        external
        payable
        returns (MessagingReceipt memory)
    {
        sendCallCount++;
        lastParams = _params;

        return MessagingReceipt({
            guid: keccak256(abi.encode(sendCallCount, _params.dstEid)),
            nonce: uint64(sendCallCount),
            fee: MessagingFee({nativeFee: feePerMessage, lzTokenFee: 0})
        });
    }

    function quote(MessagingParams calldata, address)
        external
        view
        returns (MessagingFee memory)
    {
        return MessagingFee({nativeFee: feePerMessage, lzTokenFee: 0});
    }

    function setFee(uint256 fee) external {
        feePerMessage = fee;
    }
}

contract CrossChainNotifierTest is Test {
    CrossChainNotifier public notifier;
    MockLzEndpoint public mockEndpoint;

    address public owner = address(this);
    address public nonOwner = address(0xdead);

    uint256 public constant CHAIN_A = 1;
    uint256 public constant CHAIN_B = 2;
    uint32 public constant EID_A = 30101;
    uint32 public constant EID_B = 30102;
    bytes32 public constant PEER_A = bytes32(uint256(uint160(address(0xA))));
    bytes32 public constant PEER_B = bytes32(uint256(uint160(address(0xB))));

    bytes32 public constant INTENT_ID = keccak256("test-intent-1");
    address public constant TARGET_TOKEN = address(0x1234);

    function setUp() public {
        mockEndpoint = new MockLzEndpoint();
        notifier = new CrossChainNotifier(address(mockEndpoint), owner);
    }

    // ─── registerChain ───────────────────────────────────────────────────

    function test_registerChain() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);

        (uint32 eid, bytes32 peer, bool active) = notifier.chains(CHAIN_A);
        assertEq(eid, EID_A);
        assertEq(peer, PEER_A);
        assertTrue(active);
        assertEq(notifier.getChainCount(), 1);
    }

    function test_registerChain_multiple() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);
        notifier.registerChain(CHAIN_B, EID_B, PEER_B);
        assertEq(notifier.getChainCount(), 2);
    }

    function test_registerChain_revertDuplicate() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                CrossChainNotifier.ChainAlreadyRegistered.selector, CHAIN_A
            )
        );
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);
    }

    function test_registerChain_revertNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);
    }

    // ─── deactivateChain ─────────────────────────────────────────────────

    function test_deactivateChain() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);
        notifier.deactivateChain(CHAIN_A);

        (,, bool active) = notifier.chains(CHAIN_A);
        assertFalse(active);
    }

    function test_deactivateChain_revertNotRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossChainNotifier.ChainNotRegistered.selector, CHAIN_A
            )
        );
        notifier.deactivateChain(CHAIN_A);
    }

    // ─── notifyActionExecuted ────────────────────────────────────────────

    function test_notifyActionExecuted() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);

        bytes memory params = abi.encode(uint256(2), uint256(1)); // ratio 2:1

        notifier.notifyActionExecuted{value: 0.01 ether}(
            INTENT_ID,
            ICorpActionTypes.ActionType.FORWARD_SPLIT,
            TARGET_TOKEN,
            params
        );

        assertEq(mockEndpoint.sendCallCount(), 1);
    }

    function test_notifyActionExecuted_multipleChains() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);
        notifier.registerChain(CHAIN_B, EID_B, PEER_B);

        bytes memory params = abi.encode(uint256(100));

        notifier.notifyActionExecuted{value: 0.02 ether}(
            INTENT_ID,
            ICorpActionTypes.ActionType.DIVIDEND,
            TARGET_TOKEN,
            params
        );

        assertEq(mockEndpoint.sendCallCount(), 2);
    }

    function test_notifyActionExecuted_revertNonOwner() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);

        vm.prank(nonOwner);
        vm.expectRevert();
        notifier.notifyActionExecuted{value: 0.01 ether}(
            INTENT_ID,
            ICorpActionTypes.ActionType.DIVIDEND,
            TARGET_TOKEN,
            ""
        );
    }

    function test_notifyActionExecuted_revertNoActiveChains() public {
        vm.expectRevert(
            abi.encodeWithSelector(CrossChainNotifier.NoActiveChains.selector)
        );
        notifier.notifyActionExecuted{value: 0.01 ether}(
            INTENT_ID,
            ICorpActionTypes.ActionType.DIVIDEND,
            TARGET_TOKEN,
            ""
        );
    }

    // ─── notifyDelistingInitiated ────────────────────────────────────────

    function test_notifyDelistingInitiated() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);

        uint256 effectiveDate = block.timestamp + 30 days;

        notifier.notifyDelistingInitiated{value: 0.01 ether}(
            INTENT_ID,
            TARGET_TOKEN,
            effectiveDate
        );

        assertEq(mockEndpoint.sendCallCount(), 1);
    }

    // ─── quoteBroadcastFee ───────────────────────────────────────────────

    function test_quoteBroadcastFee() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);
        notifier.registerChain(CHAIN_B, EID_B, PEER_B);

        bytes memory payload = abi.encode(uint8(1), INTENT_ID);
        uint256 fee = notifier.quoteBroadcastFee(payload);

        // 2 chains * 0.001 ether each
        assertEq(fee, 0.002 ether);
    }

    function test_quoteBroadcastFee_skipsInactive() public {
        notifier.registerChain(CHAIN_A, EID_A, PEER_A);
        notifier.registerChain(CHAIN_B, EID_B, PEER_B);
        notifier.deactivateChain(CHAIN_B);

        bytes memory payload = abi.encode(uint8(1), INTENT_ID);
        uint256 fee = notifier.quoteBroadcastFee(payload);

        // Only 1 active chain
        assertEq(fee, 0.001 ether);
    }

    // ─── Access Control ──────────────────────────────────────────────────

    function test_setDstGasLimit() public {
        notifier.setDstGasLimit(300_000);
        assertEq(notifier.dstGasLimit(), 300_000);
    }

    function test_setDstGasLimit_revertNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        notifier.setDstGasLimit(300_000);
    }

    receive() external payable {}
}
