// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAggregatorV3Interface} from "../interfaces/IAggregatorV3.sol";

/// @title ChainlinkPriceAdapter
/// @notice Adapter for fetching asset prices from Chainlink price feeds
/// @dev Maps ticker hashes to Chainlink AggregatorV3Interface feed addresses
contract ChainlinkPriceAdapter is Ownable {
    // ─── Constants ───────────────────────────────────────────────────────
    uint256 public constant MAX_PRICE_AGE = 1 hours;
    uint8 public constant CHAINLINK_DECIMALS = 8;
    uint8 public constant USDC_DECIMALS = 6;

    // ─── Storage ─────────────────────────────────────────────────────────
    /// @notice tickerHash => Chainlink feed address
    mapping(bytes32 => address) public priceFeeds;

    // ─── Errors ──────────────────────────────────────────────────────────
    error FeedNotRegistered(bytes32 tickerHash);
    error StalePrice(bytes32 tickerHash, uint256 updatedAt, uint256 maxAge);
    error InvalidPrice(bytes32 tickerHash, int256 answer);

    // ─── Events ──────────────────────────────────────────────────────────
    event PriceFeedRegistered(bytes32 indexed tickerHash, address indexed feed);
    event PriceFeedRemoved(bytes32 indexed tickerHash);

    // ─── Constructor ─────────────────────────────────────────────────────
    constructor(address _owner) Ownable(_owner) {}

    // ─── Admin ───────────────────────────────────────────────────────────

    /// @notice Register a Chainlink price feed for a given ticker
    /// @param tickerHash keccak256 of the ticker string (e.g., keccak256("AAPL"))
    /// @param feed Address of the Chainlink AggregatorV3Interface
    function registerPriceFeed(bytes32 tickerHash, address feed) external onlyOwner {
        require(feed != address(0), "feed cannot be zero address");
        priceFeeds[tickerHash] = feed;
        emit PriceFeedRegistered(tickerHash, feed);
    }

    /// @notice Remove a previously registered price feed
    /// @param tickerHash keccak256 of the ticker string
    function removePriceFeed(bytes32 tickerHash) external onlyOwner {
        delete priceFeeds[tickerHash];
        emit PriceFeedRemoved(tickerHash);
    }

    // ─── Price Queries ───────────────────────────────────────────────────

    /// @notice Get the latest price for a ticker
    /// @param tickerHash keccak256 of the ticker string
    /// @return price The price with 8 decimals
    /// @return updatedAt Timestamp of the last price update
    function getLatestPrice(bytes32 tickerHash)
        public
        view
        returns (uint256 price, uint256 updatedAt)
    {
        address feed = priceFeeds[tickerHash];
        if (feed == address(0)) revert FeedNotRegistered(tickerHash);

        (, int256 answer,, uint256 updatedAtRaw,) =
            IAggregatorV3Interface(feed).latestRoundData();

        if (answer <= 0) revert InvalidPrice(tickerHash, answer);

        if (block.timestamp - updatedAtRaw > MAX_PRICE_AGE) {
            revert StalePrice(tickerHash, updatedAtRaw, MAX_PRICE_AGE);
        }

        price = uint256(answer);
        updatedAt = updatedAtRaw;
    }

    /// @notice Calculate liquidation proceeds in USDC (6 decimals)
    /// @param tickerHash keccak256 of the ticker string
    /// @param tokenAmount Number of tokens (whole units, no decimals)
    /// @return usdcAmount Proceeds in USDC with 6 decimals
    function calculateLiquidationProceeds(bytes32 tickerHash, uint256 tokenAmount)
        external
        view
        returns (uint256 usdcAmount)
    {
        (uint256 price,) = getLatestPrice(tickerHash);

        // price is 8 decimals from Chainlink, convert to 6 decimals for USDC
        // usdcAmount = tokenAmount * price / 10^(CHAINLINK_DECIMALS - USDC_DECIMALS)
        usdcAmount = (tokenAmount * price) / (10 ** (CHAINLINK_DECIMALS - USDC_DECIMALS));
    }

    // ─── View Helpers ────────────────────────────────────────────────────

    /// @notice Check whether a price feed is registered for a ticker
    /// @param tickerHash keccak256 of the ticker string
    /// @return True if a feed is registered
    function hasFeed(bytes32 tickerHash) external view returns (bool) {
        return priceFeeds[tickerHash] != address(0);
    }
}
