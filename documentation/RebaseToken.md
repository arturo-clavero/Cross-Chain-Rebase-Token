# RebaseToken Documentation

## Overview
RebaseToken is an ETH-pegged token whose balances scale according to a global index, representing accrued interest in the vault. Users receive this token when depositing ETH, and it automatically grows in value as interest accrues.

## Key Features
- **ETH-Pegged**: Each token represents a specific ETH value.
- **Global Index Scaling**: Balances grow automatically via the `globalIndex`.
- **Conversion Functions**: `ethToRaw` and `rawToEth` handle conversion between ETH units and internal raw units.
- **Role-Based Access**:
  - `MINTER_ROLE`: Allowed to mint tokens when users deposit ETH.
  - `BURNER_ROLE`: Allowed to burn tokens when users withdraw ETH.
  - `INDEX_MANAGER_ROLE`: Updates the `globalIndex` to reflect interest accrual.

## Functions

### `mint(account, value)`
- Mints tokens for a user depositing ETH.
- **Parameters**:
  - `account` – recipient address
  - `value` – amount in ETH units
- **Role Required**: MINTER_ROLE

### `burn(account, value)`
- Burns tokens when ETH is withdrawn.
- **Parameters**:
  - `account` – target address
  - `value` – amount in ETH units
- **Role Required**: BURNER_ROLE

### `updateGlobalIndex(newValue)`
- Updates the `globalIndex` to reflect accrued interest.
- **Parameter**:
  - `newValue` – updated index in WAD units
- **Role Required**: INDEX_MANAGER_ROLE

### `balanceOf(account)`
- Returns the user balance in ETH units, scaled by `globalIndex`.

### `transfer(to, value)` / `transferFrom(from, to, value)`
- Token transfers in ETH units; internally converted to raw units.

### Conversion Utilities
- **rawToEth(raw)** – Converts raw units to ETH units.
- **ethToRaw(ETH)** – Converts ETH units to raw token units.
