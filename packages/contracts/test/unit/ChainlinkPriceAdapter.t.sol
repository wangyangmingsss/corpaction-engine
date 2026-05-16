// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChainlinkPriceAdapter} from "../../src/integrations/ChainlinkPriceAdapter.sol";
import {IAggregatorV3Interface} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Mock Chainlink aggregator for testing
contract MockAggregatorV3 is IAggregatorV3Interface {
    int256 private _answer;
    uint256 private _updatedAt;
    uint8 private _decimals;

    constructor(int256 answer_, uint256 updatedAt_, uint8 decimals_) {
        _answer = answer_;
        _updatedAt = updatedAt_;
        _decimals = decimals_;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, _updatedAt, 1);
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, _updatedAt, 1);
    }
}

contract ChainlinkPriceAdapterTest is Test {
    ChainlinkPriceAdapter public adapter;
    MockAggregatorV3 public mockFeed;

    bytes32 public constant AAPL_HASH = keccak256("AAPL");
    bytes32 public constant UNKNOWN_HASH = keccak256("UNKNOWN");

    // Price: $150.00 with 8 decimals
    int256 public constant AAPL_PRICE = 150_00000000;

    address public owner = address(this);

    function setUp() public {
        adapter = new ChainlinkPriceAdapter(owner);
        mockFeed = new MockAggregatorV3(AAPL_PRICE, block.timestamp, 8);
        adapter.registerPriceFeed(AAPL_HASH, address(mockFeed));
    }

    // ─── Registration ────────────────────────────────────────────────────

    function test_registerPriceFeed() public view {
        assertEq(adapter.priceFeeds(AAPL_HASH), address(mockFeed));
        assertTrue(adapter.hasFeed(AAPL_HASH));
    }

    function test_registerPriceFeed_revertZeroAddress() public {
        vm.expectRevert("feed cannot be zero address");
        adapter.registerPriceFeed(keccak256("ZERO"), address(0));
    }

    function test_registerPriceFeed_revertNonOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        adapter.registerPriceFeed(keccak256("GOOG"), address(mockFeed));
    }

    function test_removePriceFeed() public {
        adapter.removePriceFeed(AAPL_HASH);
        assertFalse(adapter.hasFeed(AAPL_HASH));
    }

    // ─── Normal Price Fetch ──────────────────────────────────────────────

    function test_getLatestPrice() public view {
        (uint256 price, uint256 updatedAt) = adapter.getLatestPrice(AAPL_HASH);
        assertEq(price, uint256(AAPL_PRICE));
        assertEq(updatedAt, block.timestamp);
    }

    // ─── Feed Not Registered ─────────────────────────────────────────────

    function test_getLatestPrice_revertFeedNotRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceAdapter.FeedNotRegistered.selector, UNKNOWN_HASH
            )
        );
        adapter.getLatestPrice(UNKNOWN_HASH);
    }

    // ─── Stale Price ─────────────────────────────────────────────────────

    function test_getLatestPrice_revertStalePrice() public {
        // Set updatedAt to 2 hours ago
        uint256 staleTime = block.timestamp - 2 hours;
        mockFeed.setUpdatedAt(staleTime);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceAdapter.StalePrice.selector,
                AAPL_HASH,
                staleTime,
                adapter.MAX_PRICE_AGE()
            )
        );
        adapter.getLatestPrice(AAPL_HASH);
    }

    // ─── Invalid Price ───────────────────────────────────────────────────

    function test_getLatestPrice_revertInvalidPrice_zero() public {
        mockFeed.setAnswer(0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceAdapter.InvalidPrice.selector, AAPL_HASH, int256(0)
            )
        );
        adapter.getLatestPrice(AAPL_HASH);
    }

    function test_getLatestPrice_revertInvalidPrice_negative() public {
        mockFeed.setAnswer(-1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceAdapter.InvalidPrice.selector, AAPL_HASH, int256(-1)
            )
        );
        adapter.getLatestPrice(AAPL_HASH);
    }

    // ─── Liquidation Proceeds ────────────────────────────────────────────

    function test_calculateLiquidationProceeds() public view {
        // 100 tokens at $150.00 each = $15,000 in USDC (6 decimals)
        uint256 proceeds = adapter.calculateLiquidationProceeds(AAPL_HASH, 100);

        // 100 * 150_00000000 / 10^2 = 150_000000 (i.e., 150.000000 per token * 100)
        // = 15000_000000 USDC
        assertEq(proceeds, 15_000_000000);
    }

    function test_calculateLiquidationProceeds_singleToken() public view {
        uint256 proceeds = adapter.calculateLiquidationProceeds(AAPL_HASH, 1);
        // 1 * 150_00000000 / 100 = 150_000000
        assertEq(proceeds, 150_000000);
    }

    function test_calculateLiquidationProceeds_zeroTokens() public view {
        uint256 proceeds = adapter.calculateLiquidationProceeds(AAPL_HASH, 0);
        assertEq(proceeds, 0);
    }
}
