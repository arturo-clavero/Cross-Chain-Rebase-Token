// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceConverter {
    error PriceConverter__InvalidChainLinkRate();
    error PriceConverter__InvalidAmount();
    error PriceConverter__UnsupportedCurrency();

    /// @dev Only supports "USD" as currency currently
    /// @param amount The fiat amount to convert (e.g., $50 = 50)
    /// @param priceFeed The Chainlink price feed contract address
    /// @return The equivalent amount in wei (ETH)
    function getRates(uint256 amount, address priceFeed) external view returns (uint256) {
        if (amount == 0) {
            revert PriceConverter__InvalidAmount();
        }
        if (priceFeed == address(0)) {
            revert PriceConverter__UnsupportedCurrency();
        }
        // @dev Currently only USD is supported
        return getLatestPrice(AggregatorV3Interface(priceFeed), amount);
    }

    /// @dev Chainlink feeds usually return 8 decimal values for USD
    /// @param priceFeed The Chainlink AggregatorV3Interface
    /// @param amount The fiat amount to convert
    /// @return The converted amount in wei
    function getLatestPrice(AggregatorV3Interface priceFeed, uint256 amount) internal view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        return convert(amount, answer, priceFeed.decimals());
    }

    /// @dev Handles Chainlink’s decimal scaling
    /// @param amount The fiat amount to convert
    /// @param rate The ETH/USD rate returned by Chainlink (usually 8 decimals)
    /// @param chainLinkDecimals The number of decimals used by the feed (e.g., 1e8 for USD)
    /// @return The resulting amount in wei (ETH)
    function convert(uint256 amount, int256 rate, uint256 chainLinkDecimals) internal pure returns (uint256) {
        if (rate <= 0) revert PriceConverter__InvalidChainLinkRate();
        return (amount * uint256(rate)) / (10 ** chainLinkDecimals);
    }
}
