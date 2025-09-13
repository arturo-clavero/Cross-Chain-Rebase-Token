# RebaseToken Project

## Overview

RebaseToken is an ETH-pegged rebase token designed to represent deposits in a vault while **automatically accruing interest**.
This system consists of:

* **RebaseToken.sol**: ERC20 token with balances scaled by a `globalIndex`
* **Vault.sol**: Borrowing/lending vault with collateralized debt positions
* **PriceConverter.sol**: Library for converting collateral token values to ETH

---

## Design Choices

### 1. Rebase Token Structure

* Pegged 1:1 to ETH deposits
* Balances scale with `globalIndex` to reflect accrued interest
* Conversion helpers:

  * `ethToRaw` — converts ETH value into raw token units
  * `rawToEth` — converts raw token units into ETH value

This ensures depositors see balances grow as vault interest accumulates.

---

### 2. Role-Based Access

* `MINTER_ROLE`: Mint tokens for deposits
* `BURNER_ROLE`: Burn tokens for withdrawals
* `INDEX_MANAGER_ROLE`: Update `globalIndex` to distribute interest

Roles restrict who can mint, burn, or update the index, ensuring safety of the system.

---

### 3. Vault Interaction

* **Deposits**: Users deposit ETH, minting RebaseToken in return
* **Withdrawals**: Users burn RebaseToken to reclaim ETH
* **Borrowing**: Users borrow ETH against ERC20 collateral (with loan-to-value limits)
* **Repayment**: Repaying ETH reduces debt and unlocks collateral

Balances and debts are **always calculated relative to the global index**, so interest accrual is automatic.

---

### 4. Interest Accrual

* A **global interest index** (`globalIndex`) starts at `1e18`
* It is periodically updated by an `INDEX_MANAGER_ROLE` account via `accrueRebaseTokenInterest()`
* Example update formula:

  ```
  newIndex = oldIndex * (totalDeposits + totalInterests) / totalDeposits
  ```
* Each user’s debt and balance scale automatically with the new index

This avoids looping over all accounts and keeps the system gas-efficient.

---

### 5. Price Conversion

* Chainlink price feeds convert collateral token amounts into ETH
* Loan-to-Value Multiplier (`LVM`) defines borrowing limits per token
* Example:

  ```
  maxBorrow = collateralAmount * price * LVM
  ```

---

### 6. liquidity

* A user is liquidatable if their **health factor < 1**:

  ```
  healthFactor = (collateralValue * LVM) / totalDebt
  ```
* liquidity process:

  1. Liquidator pays ETH to cover part (or all) of the debt
  2. Equivalent (or discounted) collateral is seized and transferred to the liquidator
  3. User’s debt and collateral balance are reduced proportionally
  4. Any excess ETH sent by liquidator is refunded

This mechanism keeps the vault solvent and incentivizes third parties to maintain healthy positions.

---

## Usage

1. Deploy **RebaseToken** (name, symbol, admin)
2. Deploy **Vault** linked to RebaseToken
3. Add supported collateral tokens with Chainlink feeds and LVMs
4. Users deposit ETH → receive RebaseToken
5. Users borrow ETH using collateral
6. Interest accrues via global index updates
7. Users repay ETH to reclaim collateral
8. If undercollateralized, positions can be liquidated

---

## Documentation

More detailed documentation is available in the `documentation` folder:

* `RebaseToken.md` – Token mechanics and role management
* `Vault.md` – Deposit, borrow, repay, interest logic, liquidity
* `PriceConverter.md` – Collateral conversion mechanics
* `Whitepaper.md` – High-level overview, purpose, and intended usage

