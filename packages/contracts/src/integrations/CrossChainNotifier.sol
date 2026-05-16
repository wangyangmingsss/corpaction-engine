// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingReceipt,
    MessagingFee
} from "../interfaces/ILayerZero.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";

/// @title CrossChainNotifier
/// @notice Broadcasts corporate action events to destination chains via LayerZero V2
contract CrossChainNotifier is Ownable {
    // ─── Message Types ───────────────────────────────────────────────────
    uint8 public constant MSG_ACTION_EXECUTED = 1;
    uint8 public constant MSG_EMERGENCY_PAUSE = 2;
    uint8 public constant MSG_DELISTING_INITIATED = 3;

    // ─── Structs ─────────────────────────────────────────────────────────
    struct ChainConfig {
        uint32 eid;
        bytes32 peer;
        bool active;
    }

    // ─── Storage ─────────────────────────────────────────────────────────
    ILayerZeroEndpointV2 public immutable endpoint;

    /// @notice chainId => ChainConfig
    mapping(uint256 => ChainConfig) public chains;

    /// @notice List of registered chain IDs for iteration
    uint256[] public chainIds;

    /// @notice Default gas limit for destination execution
    uint128 public dstGasLimit = 200_000;

    // ─── Errors ──────────────────────────────────────────────────────────
    error NoActiveChains();
    error ChainAlreadyRegistered(uint256 chainId);
    error ChainNotRegistered(uint256 chainId);
    error InsufficientFee(uint256 required, uint256 provided);

    // ─── Events ──────────────────────────────────────────────────────────
    event ChainRegistered(uint256 indexed chainId, uint32 eid, bytes32 peer);
    event ChainDeactivated(uint256 indexed chainId);
    event ActionBroadcasted(
        bytes32 indexed intentId,
        uint8 msgType,
        uint256 chainCount
    );

    // ─── Constructor ─────────────────────────────────────────────────────
    constructor(address _endpoint, address _owner) Ownable(_owner) {
        endpoint = ILayerZeroEndpointV2(_endpoint);
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Register a destination chain for cross-chain messaging
    /// @param chainId Logical chain identifier
    /// @param eid LayerZero endpoint ID for the destination
    /// @param peer Address of the receiver contract on the destination (as bytes32)
    function registerChain(uint256 chainId, uint32 eid, bytes32 peer) external onlyOwner {
        if (chains[chainId].eid != 0) revert ChainAlreadyRegistered(chainId);

        chains[chainId] = ChainConfig({eid: eid, peer: peer, active: true});
        chainIds.push(chainId);
        emit ChainRegistered(chainId, eid, peer);
    }

    /// @notice Deactivate a destination chain
    /// @param chainId Logical chain identifier
    function deactivateChain(uint256 chainId) external onlyOwner {
        if (chains[chainId].eid == 0) revert ChainNotRegistered(chainId);
        chains[chainId].active = false;
        emit ChainDeactivated(chainId);
    }

    /// @notice Update the default destination gas limit
    /// @param _gasLimit New gas limit
    function setDstGasLimit(uint128 _gasLimit) external onlyOwner {
        dstGasLimit = _gasLimit;
    }

    // ─── Broadcasting ────────────────────────────────────────────────────

    /// @notice Broadcast that a corporate action was executed
    /// @param intentId The action intent identifier
    /// @param actionType The type of corporate action
    /// @param targetToken The token address affected
    /// @param actionParams Encoded action parameters
    function notifyActionExecuted(
        bytes32 intentId,
        ICorpActionTypes.ActionType actionType,
        address targetToken,
        bytes calldata actionParams
    ) external payable onlyOwner {
        bytes memory payload = abi.encode(
            MSG_ACTION_EXECUTED,
            intentId,
            uint8(actionType),
            targetToken,
            actionParams,
            block.timestamp
        );

        uint256 sent = _broadcastToAllChains(payload);
        emit ActionBroadcasted(intentId, MSG_ACTION_EXECUTED, sent);
    }

    /// @notice Broadcast an emergency delisting notification
    /// @param intentId The action intent identifier
    /// @param targetToken The token being delisted
    /// @param effectiveDate When the delisting takes effect
    function notifyDelistingInitiated(
        bytes32 intentId,
        address targetToken,
        uint256 effectiveDate
    ) external payable onlyOwner {
        bytes memory payload = abi.encode(
            MSG_DELISTING_INITIATED,
            intentId,
            targetToken,
            effectiveDate,
            block.timestamp
        );

        uint256 sent = _broadcastToAllChains(payload);
        emit ActionBroadcasted(intentId, MSG_DELISTING_INITIATED, sent);
    }

    // ─── Fee Estimation ──────────────────────────────────────────────────

    /// @notice Estimate the total fee to broadcast to all active chains
    /// @param payload The encoded message payload
    /// @return totalNativeFee Total native token fee across all chains
    function quoteBroadcastFee(bytes memory payload)
        external
        view
        returns (uint256 totalNativeFee)
    {
        for (uint256 i = 0; i < chainIds.length; i++) {
            ChainConfig memory cfg = chains[chainIds[i]];
            if (!cfg.active) continue;

            MessagingParams memory params = MessagingParams({
                dstEid: cfg.eid,
                receiver: cfg.peer,
                message: payload,
                options: _buildOptions(),
                payInLzToken: false
            });

            MessagingFee memory fee = endpoint.quote(params, address(this));
            totalNativeFee += fee.nativeFee;
        }
    }

    // ─── Internal ────────────────────────────────────────────────────────

    function _broadcastToAllChains(bytes memory payload)
        internal
        returns (uint256 sentCount)
    {
        for (uint256 i = 0; i < chainIds.length; i++) {
            ChainConfig memory cfg = chains[chainIds[i]];
            if (!cfg.active) continue;

            MessagingParams memory params = MessagingParams({
                dstEid: cfg.eid,
                receiver: cfg.peer,
                message: payload,
                options: _buildOptions(),
                payInLzToken: false
            });

            endpoint.send{value: msg.value / _activeChainCount()}(
                params,
                msg.sender
            );

            sentCount++;
        }

        if (sentCount == 0) revert NoActiveChains();
    }

    function _activeChainCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (chains[chainIds[i]].active) count++;
        }
    }

    /// @dev Build minimal executor options (gas limit for destination)
    function _buildOptions() internal view returns (bytes memory) {
        return abi.encodePacked(uint16(1), dstGasLimit);
    }

    /// @notice Get the number of registered chains
    function getChainCount() external view returns (uint256) {
        return chainIds.length;
    }
}
