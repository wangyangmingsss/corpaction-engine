// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library MultiplierMath {
    uint256 constant MULTIPLIER_DECIMALS = 18;
    uint256 constant MULTIPLIER_BASE = 10 ** MULTIPLIER_DECIMALS;

    error Overflow();
    error DivisionByZero();

    function mulMultiplier(
        uint256 current, uint256 numerator, uint256 denominator
    ) internal pure returns (uint256) {
        if (denominator == 0) revert DivisionByZero();
        uint256 result = (current * numerator) / denominator;
        if (result == 0) revert Overflow();
        return result;
    }

    function divMultiplier(
        uint256 current, uint256 numerator, uint256 denominator
    ) internal pure returns (uint256) {
        if (numerator == 0) revert DivisionByZero();
        uint256 result = (current * denominator) / numerator;
        if (result == 0) revert Overflow();
        return result;
    }

    function toUIAmount(
        uint256 rawBalance, uint256 multiplier
    ) internal pure returns (uint256) {
        return (rawBalance * multiplier) / MULTIPLIER_BASE;
    }

    function fromUIAmount(
        uint256 uiAmount, uint256 multiplier
    ) internal pure returns (uint256) {
        if (multiplier == 0) revert DivisionByZero();
        return (uiAmount * MULTIPLIER_BASE) / multiplier;
    }
}
