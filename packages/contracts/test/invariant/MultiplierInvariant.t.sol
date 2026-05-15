// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MultiplierMath} from "../../src/libraries/MultiplierMath.sol";
import {MockERC8056} from "../mocks/MockERC8056.sol";

contract MultiplierInvariantHandler is Test {
    MockERC8056 public token;
    address public holder;

    constructor(MockERC8056 _token, address _holder) {
        token = _token;
        holder = _holder;
    }

    function applyForwardSplit(uint256 numerator) external {
        numerator = bound(numerator, 2, 100);
        uint256 oldMul = token.uiMultiplier();
        uint256 newMul = MultiplierMath.mulMultiplier(oldMul, numerator, 1);
        token.setUIMultiplier(newMul);
    }

    function applyReverseSplit(uint256 denominator) external {
        denominator = bound(denominator, 2, 20);
        uint256 oldMul = token.uiMultiplier();
        uint256 newMul = MultiplierMath.divMultiplier(oldMul, denominator, 1);
        if (newMul > 0) {
            token.setUIMultiplier(newMul);
        }
    }
}

contract MultiplierInvariantTest is Test {
    MockERC8056 public token;
    MultiplierInvariantHandler public handler;
    address public holder = makeAddr("holder");
    uint256 public constant RAW_BALANCE = 1000e18;

    function setUp() public {
        token = new MockERC8056("Test", "TST", 18);
        token.mint(holder, RAW_BALANCE);

        handler = new MultiplierInvariantHandler(token, holder);
        targetContract(address(handler));
    }

    /// @dev Invariant: UI multiplier * raw balance == UI balance (within rounding)
    function invariant_uiMultiplierTimesRawEqualsUIBalance() public view {
        uint256 multiplier = token.uiMultiplier();
        uint256 rawBalance = token.balanceOf(holder);
        uint256 uiBalance = token.balanceOfUI(holder);

        uint256 expected = (rawBalance * multiplier) / 1e18;
        assertEq(uiBalance, expected);
    }

    /// @dev Invariant: raw balance never changes due to multiplier operations
    function invariant_rawBalanceUnchanged() public view {
        assertEq(token.balanceOf(holder), RAW_BALANCE);
    }

    /// @dev Invariant: multiplier is always positive
    function invariant_multiplierPositive() public view {
        assertGt(token.uiMultiplier(), 0);
    }
}
