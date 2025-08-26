# PriceConverter Documentation

## Overview
PriceConverter is a library for converting collateral token amounts to ETH equivalents using Chainlink price feeds.

## Functions

### `getRates(amount, priceFeed)`
- Returns ETH equivalent for a given collateral amount.
- **Parameters**:
  - `amount` – collateral amount in token units
  - `priceFeed` – address of Chainlink Aggregator
- **Returns**: Amount in wei (ETH units)

### `getLatestPrice(priceFeed, amount)`
- Internal function that retrieves the latest price from Chainlink.
- Uses `convert` to scale based on decimals.

### `convert(amount, rate, chainLinkDecimals)`
- Handles decimal scaling of the Chainlink feed.
- **Parameters**:
  - `amount` – collateral amount
  - `rate` – rate from Chainlink feed
  - `chainLinkDecimals` – decimals used by the feed
- **Returns**: Converted amount in ETH units
