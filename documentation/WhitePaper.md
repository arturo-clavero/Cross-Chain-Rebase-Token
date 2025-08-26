# RebaseToken Whitepaper

## Purpose
RebaseToken is designed to represent ETH deposits in a vault while reflecting interest accrual automatically. Its purpose is to allow users to safely deposit, borrow, and manage collateral in a decentralized manner.

## Core Concepts

1. **ETH-Pegged Rebase Token**
   - Always represents a value in ETH.
   - Balances grow automatically using a `globalIndex`.

2. **Vault System**
   - Users deposit ETH and receive RebaseToken.
   - Users can borrow ETH against supported ERC20 tokens as collateral.
   - Collateral values are converted to ETH using Chainlink price feeds.

3. **Interest Accrual**
   - Global index grows over time or via admin-set interest rate.
   - Token balances automatically scale without per-user updates.

4. **Role-Based Security**
   - Specific roles control minting, burning, collateral management, and index updates.

## Advantages
- Transparent, on-chain interest accrual.
- Gas-efficient scaling of balances.
- Safe borrowing using LVM and Chainlink feeds.
- Fully auditable and modular system.

## Usage
- Deploy contracts, assign roles.
- Users deposit ETH, borrow ETH against collateral, repay ETH.
- Interest accrues automatically via the global index.
- Token balances always reflect accrued interest in ETH units.
