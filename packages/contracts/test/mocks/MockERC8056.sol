// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC8056} from "../../src/interfaces/IERC8056.sol";

contract MockERC8056 is ERC20, IERC8056 {
    uint256 private _uiMultiplier;
    uint8 private _decimals;
    address public multiplierAdmin;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        _uiMultiplier = 1e18; // 1.0x
        multiplierAdmin = msg.sender;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function uiMultiplier() external view override returns (uint256) {
        return _uiMultiplier;
    }

    function setUIMultiplier(uint256 newMultiplier) external override {
        uint256 old = _uiMultiplier;
        _uiMultiplier = newMultiplier;
        emit UIMultiplierUpdated(old, newMultiplier);
    }

    function balanceOfUI(address account) external view override returns (uint256) {
        return (balanceOf(account) * _uiMultiplier) / 1e18;
    }

    function toUIAmount(uint256 rawAmount) external view override returns (uint256) {
        return (rawAmount * _uiMultiplier) / 1e18;
    }

    function fromUIAmount(uint256 uiAmount) external view override returns (uint256) {
        return (uiAmount * 1e18) / _uiMultiplier;
    }
}
