# Vault Documentation

## Overview

The Vault allows users to deposit ETH, borrow ETH against collateral, and repay borrowed ETH while interest accrues over time. Deposits are represented by **RebaseToken**, and collateral is **ERC20 tokens**. If users fall below the required health factor, their positions can be liquidated.

---

## Key Features

* **Deposit / Withdraw ETH**
* **Borrow ETH against ERC20 collateral**
* **Repay ETH and reclaim collateral proportionally**
* **Interest Accrual** using a global interest index
* **Collateral Management** with Chainlink price feeds
* **liquidity** when borrowers become undercollateralized

---

## Roles

* `INTEREST_MANAGER_ROLE` – Can update global interest index
* `COLLATERAL_MANAGER_ROLE` – Can add or modify supported collateral
* `LIQUIDATOR_ROLE` (optional) – Any address may call liquidity, but role can be restricted

---

## Functions

### `deposit()`

* Deposits ETH and mints RebaseToken to the sender.

### `withdraw(amount)`

* Burns RebaseToken and withdraws ETH from the vault.
* **Checks**: amount > 0, sufficient balance.

### `borrow(token, amount)`

* Borrow ETH against ERC20 collateral.
* **Checks**:

  * collateral is supported
  * user allowance for collateral transfer
  * vault liquidity is sufficient
  * user health factor remains ≥ 1 after borrowing
* **Effects**:

  * Updates user debt using current global interest index
  * Locks collateral and transfers ETH to borrower

### `repay(token)`

* Repay borrowed ETH.
* Returns proportional collateral.
* Updates user debt using global index before repayment.

---

## Interest Accrual

* **Global Index (`interestIndex`)**

  * Scales all users’ debts by a single multiplier.
  * Starts at `1e18`.
  * Increases over time according to the interest rate.

* **Interest Rate**

  * Typically calculated per block or per second.
  * Example formula:

    ```
    newIndex = interestIndex * (1 + rate * timeDelta)
    ```

    where `rate` is annualized interest (scaled), and `timeDelta` is time since last update.

* **User Debt Calculation**

  * Each user stores a `debtBase` (amount borrowed at the time of last interaction).
  * Actual debt owed is:

    ```
    debt = debtBase * (currentInterestIndex / userInterestIndex)
    ```
  * When borrowing or repaying, the user’s `userInterestIndex` is updated to `currentInterestIndex`.

---

## Collateral Management

* `addCollateral(token, priceFeed, LVM)` – Add new supported token.
* `modifyCollateralPriceFeed(token, priceFeed)` – Update price feed.
* `modifyCollateralLVM(token, LVM)` – Update loan-to-value multiplier (LVM).

---

## liquidity

### Trigger

A user becomes eligible for liquidity if their **health factor < 1**:

```
healthFactor = (collateralValue * LVM) / totalDebt
```

* `collateralValue` = token balance \* Chainlink price
* `LVM` = Loan-to-Value multiplier (e.g., 75%)
* `totalDebt` = user’s outstanding ETH debt (with interest applied)

### `liquidate(user)`

* Can be called by any account (or restricted to role).
* **Checks**:

  * User’s health factor < 1
* **Effects**:

  * Part or all of user’s collateral is seized
  * Equivalent debt is repaid on user’s behalf
  * Liquidator receives discounted collateral (e.g., 5–10% bonus)

---
