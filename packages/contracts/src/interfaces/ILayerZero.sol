// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILayerZero
/// @notice Minimal LayerZero V2 interfaces for local development
/// @dev Mirrors the essential LayerZero V2 endpoint and messaging types

/// @notice Fee estimation structure returned by LayerZero endpoint
struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

/// @notice Receipt returned after a message is sent
struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

/// @notice Parameters for sending a message via LayerZero
struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

/// @notice Origin information for received messages
struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

/// @notice Minimal LayerZero V2 endpoint interface
interface ILayerZeroEndpointV2 {
    function send(
        MessagingParams calldata _params,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory);

    function quote(
        MessagingParams calldata _params,
        address _sender
    ) external view returns (MessagingFee memory);
}

/// @notice Interface that receivers must implement
interface ILayerZeroReceiver {
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}
