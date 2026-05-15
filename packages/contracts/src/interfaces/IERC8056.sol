// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC8056 is IERC20 {
    function uiMultiplier() external view returns (uint256);
    function setUIMultiplier(uint256 newMultiplier) external;
    function balanceOfUI(address account) external view returns (uint256);
    function toUIAmount(uint256 rawAmount) external view returns (uint256);
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);
}
