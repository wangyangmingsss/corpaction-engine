// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MultiplierMath} from "../../src/libraries/MultiplierMath.sol";

// Wrapper contract to test library reverts via external calls
contract MultiplierMathWrapper {
    function mulMultiplier(uint256 current, uint256 numerator, uint256 denominator)
        external pure returns (uint256) {
        return MultiplierMath.mulMultiplier(current, numerator, denominator);
    }

    function divMultiplier(uint256 current, uint256 numerator, uint256 denominator)
        external pure returns (uint256) {
        return MultiplierMath.divMultiplier(current, numerator, denominator);
    }

    function fromUIAmount(uint256 uiAmount, uint256 multiplier)
        external pure returns (uint256) {
        return MultiplierMath.fromUIAmount(uiAmount, multiplier);
    }
}

contract MultiplierMathTest is Test {
    uint256 constant BASE = 1e18;
    MultiplierMathWrapper wrapper;

    function setUp() public {
        wrapper = new MultiplierMathWrapper();
    }

    function test_mulMultiplier_forwardSplit() public pure {
        uint256 result = MultiplierMath.mulMultiplier(BASE, 4, 1);
        assertEq(result, 4e18);
    }

    function test_mulMultiplier_10to1Split() public pure {
        uint256 result = MultiplierMath.mulMultiplier(BASE, 10, 1);
        assertEq(result, 10e18);
    }

    function test_divMultiplier_reverseSplit() public pure {
        uint256 result = MultiplierMath.divMultiplier(BASE, 10, 1);
        assertEq(result, 0.1e18);
    }

    function test_mulMultiplier_fractionalSplit() public pure {
        uint256 result = MultiplierMath.mulMultiplier(BASE, 3, 2);
        assertEq(result, 1.5e18);
    }

    function test_toUIAmount() public pure {
        uint256 rawBalance = 100e18;
        uint256 multiplier = 4e18;
        uint256 uiAmount = MultiplierMath.toUIAmount(rawBalance, multiplier);
        assertEq(uiAmount, 400e18);
    }

    function test_fromUIAmount() public pure {
        uint256 uiAmount = 400e18;
        uint256 multiplier = 4e18;
        uint256 raw = MultiplierMath.fromUIAmount(uiAmount, multiplier);
        assertEq(raw, 100e18);
    }

    function test_revert_divisionByZero_mul() public {
        vm.expectRevert(MultiplierMath.DivisionByZero.selector);
        wrapper.mulMultiplier(BASE, 4, 0);
    }

    function test_revert_divisionByZero_div() public {
        vm.expectRevert(MultiplierMath.DivisionByZero.selector);
        wrapper.divMultiplier(BASE, 0, 1);
    }

    function test_revert_divisionByZero_fromUIAmount() public {
        vm.expectRevert(MultiplierMath.DivisionByZero.selector);
        wrapper.fromUIAmount(100e18, 0);
    }
}
