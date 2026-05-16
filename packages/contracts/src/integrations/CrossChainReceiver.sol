// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ILayerZeroReceiver,
    Origin
} from "../interfaces/ILayerZero.sol";

/// @title CrossChainReceiver
/// @notice Receives cross-chain corporate action notifications via LayerZero V2
/// @dev Deployed on destination chains to decode and emit events
contract CrossChainReceiver is Ownable, ILayerZeroReceiver {
    // ─── Message Types (must match CrossChainNotifier) ───────────────────
    uint8 public constant MSG_ACTION_EXECUTED = 1;
    uint8 public constant MSG_EMERGENCY_PAUSE = 2;
    uint8 public constant MSG_DELISTING_INITIATED = 3;

    // ─── Storage ─────────────────────────────────────────────────────────
    address public immutable lzEndpoint;

    /// @notice Trusted source endpoint ID => sender bytes32
    mapping(uint32 => bytes32) public trustedSenders;

    // ─── Errors ──────────────────────────────────────────────────────────
    error UnauthorizedEndpoint(address caller);
    error UntrustedSender(uint32 srcEid, bytes32 sender);
    error UnknownMessageType(uint8 msgType);

    // ─── Events ──────────────────────────────────────────────────────────
    event CorporateActionReceived(
        uint32 indexed srcEid,
        bytes32 indexed intentId,
        uint8 actionType,
        address targetToken,
        bytes actionParams,
        uint256 sourceTimestamp
    );

    event DelistingWarning(
        uint32 indexed srcEid,
        bytes32 indexed intentId,
        address targetToken,
        uint256 effectiveDate,
        uint256 sourceTimestamp
    );

    event EmergencyPauseReceived(
        uint32 indexed srcEid,
        bytes32 indexed intentId,
        uint256 sourceTimestamp
    );

    // ─── Constructor ─────────────────────────────────────────────────────
    constructor(address _lzEndpoint, address _owner) Ownable(_owner) {
        lzEndpoint = _lzEndpoint;
    }

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Set a trusted sender for a source endpoint ID
    /// @param srcEid The LayerZero endpoint ID of the source chain
    /// @param sender The trusted sender address as bytes32
    function setTrustedSender(uint32 srcEid, bytes32 sender) external onlyOwner {
        trustedSenders[srcEid] = sender;
    }

    // ─── LayerZero Receive ───────────────────────────────────────────────

    /// @inheritdoc ILayerZeroReceiver
    function lzReceive(
        Origin calldata _origin,
        bytes32,
        bytes calldata _message,
        address,
        bytes calldata
    ) external payable {
        if (msg.sender != lzEndpoint) revert UnauthorizedEndpoint(msg.sender);

        bytes32 trusted = trustedSenders[_origin.srcEid];
        if (trusted == bytes32(0) || trusted != _origin.sender) {
            revert UntrustedSender(_origin.srcEid, _origin.sender);
        }

        _processMessage(_origin.srcEid, _message);
    }

    // ─── Internal ────────────────────────────────────────────────────────

    function _processMessage(uint32 srcEid, bytes calldata message) internal {
        uint8 msgType = abi.decode(message, (uint8));

        if (msgType == MSG_ACTION_EXECUTED) {
            _handleActionExecuted(srcEid, message);
        } else if (msgType == MSG_DELISTING_INITIATED) {
            _handleDelistingInitiated(srcEid, message);
        } else if (msgType == MSG_EMERGENCY_PAUSE) {
            _handleEmergencyPause(srcEid, message);
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    function _handleActionExecuted(uint32 srcEid, bytes calldata message) internal {
        (
            ,
            bytes32 intentId,
            uint8 actionType,
            address targetToken,
            bytes memory actionParams,
            uint256 sourceTimestamp
        ) = abi.decode(message, (uint8, bytes32, uint8, address, bytes, uint256));

        emit CorporateActionReceived(
            srcEid, intentId, actionType, targetToken, actionParams, sourceTimestamp
        );
    }

    function _handleDelistingInitiated(uint32 srcEid, bytes calldata message) internal {
        (
            ,
            bytes32 intentId,
            address targetToken,
            uint256 effectiveDate,
            uint256 sourceTimestamp
        ) = abi.decode(message, (uint8, bytes32, address, uint256, uint256));

        emit DelistingWarning(srcEid, intentId, targetToken, effectiveDate, sourceTimestamp);
    }

    function _handleEmergencyPause(uint32 srcEid, bytes calldata message) internal {
        (, bytes32 intentId, uint256 sourceTimestamp) =
            abi.decode(message, (uint8, bytes32, uint256));

        emit EmergencyPauseReceived(srcEid, intentId, sourceTimestamp);
    }
}
