// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MultiplierMath} from "../../src/libraries/MultiplierMath.sol";

contract MultiplierMathFuzzTest is Test {
    function testFuzz_mulDivRoundTrip(
        uint256 multiplier, uint256 numerator, uint256 denominator
    ) public pure {
        // Use bound() instead of assume() to avoid rejection
        multiplier = bound(multiplier, 1e18, 1000e18);
        numerator = bound(numerator, 1, 100);
        denominator = bound(denominator, 1, 100);

        uint256 afterMul = MultiplierMath.mulMultiplier(
            multiplier, numerator, denominator
        );

        uint256 afterDiv = MultiplierMath.divMultiplier(
            afterMul, numerator, denominator
        );

        // Allow rounding error proportional to denominator
        assertApproxEqAbs(afterDiv, multiplier, denominator);
    }

    function testFuzz_toFromUIAmount(
        uint256 rawBalance, uint256 multiplier
    ) public pure {
        vm.assume(rawBalance > 1e18 && rawBalance < type(uint128).max);
        vm.assume(multiplier > 1e15 && multiplier < type(uint128).max);

        uint256 uiAmount = MultiplierMath.toUIAmount(rawBalance, multiplier);
        vm.assume(uiAmount > 0);

        uint256 backToRaw = MultiplierMath.fromUIAmount(uiAmount, multiplier);

        // Allow rounding error
        assertApproxEqAbs(backToRaw, rawBalance, 1e18);
    }
}
