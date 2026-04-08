# Vault E2E Test Plan - Polygon Amoy

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Network | Polygon Amoy testnet (chain ID 80002) |
| Wallet | Funded with MATIC (gas) + at least 10 USDC |
| Deployed contracts | Vault, USDC, ConditionalTokens, MarketFactory, at least one FPMM market with liquidity |
| Amoy RPC | Configured in `.env` as `AMOY_RPC_URL` |
| Private key | Wallet private key in `.env` as `PRIVATE_KEY` |

### Required `.env` variables

```bash
PRIVATE_KEY=0x...
AMOY_RPC_URL=https://rpc-amoy.polygon.technology
VAULT_ADDRESS=0x...
USDC_ADDRESS=0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582
MARKET_ADDRESS=0x...          # An existing FPMM market with liquidity
CONDITIONAL_TOKENS=0x...
```

## How to run

```bash
cd packages/contracts

# Dry run (simulation only, no on-chain txs)
forge script script/VaultE2E.s.sol --rpc-url amoy -vvvv

# Live run (broadcasts real transactions)
forge script script/VaultE2E.s.sol --rpc-url amoy --broadcast -vvvv
```

## Test flow

| Step | Action | Verification |
|------|--------|-------------|
| 1. Deposit | `approve(vault, 10 USDC)` then `vault.deposit(10 USDC)` | `vault.balanceOf(user) == 10 USDC` |
| 2. Buy YES | `vault.buyPosition(market, 0, 5 USDC, 0)` | `vault.balanceOf(user) == 5 USDC`, `vault.getPosition(user, positionId) > 0` |
| 3. Sell YES | `vault.sellPosition(market, 0, 2 USDC, maxTokens)` | Balance increased, position decreased |
| 4. Withdraw | `vault.withdraw(remaining)` | `vault.balanceOf(user) == 0` |

## Expected outcomes

- **Step 1**: Vault holds 10 USDC on behalf of user. User's external USDC decreases by 10.
- **Step 2**: 5 USDC is sent to the FPMM. User receives YES outcome tokens tracked in `vault.positions`. Vault USDC balance drops to 5.
- **Step 3**: Some outcome tokens are sold back to FPMM for ~2 USDC. Vault USDC balance increases. Outcome token position decreases.
- **Step 4**: All remaining USDC withdrawn. Vault balance goes to 0. User still holds leftover outcome tokens in the Vault (redeemable after market resolution).

## Not covered by this script

These require market resolution (UMA oracle assertion + liveness period):

- `vault.redeemPosition()` - redeem outcome tokens after market resolves
- Full round-trip P&L accounting

## Manual checklist

- [ ] Verify `.env` has all required addresses
- [ ] Verify wallet has enough USDC (>= 10) and MATIC for gas
- [ ] Verify the target FPMM market has liquidity
- [ ] Run dry-run first (`forge script` without `--broadcast`)
- [ ] Review simulated output for all `[PASS]` markers
- [ ] Run with `--broadcast` for live execution
- [ ] Check Polygonscan Amoy for transaction confirmations
- [ ] Verify outcome token balance on ConditionalTokens contract matches vault tracking
