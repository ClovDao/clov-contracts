# clov-contracts

Smart contracts for **Clov**, a decentralized sports prediction market on
Polygon PoS. The protocol uses a Polymarket-style CLOB (Central Limit Order
Book) over Gnosis Conditional Tokens, with UMA Optimistic Oracle V3 for
dispute resolution and a creator-funded community-market lifecycle.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](foundry.toml)
[![Network: Polygon](https://img.shields.io/badge/Network-Polygon-8247E5.svg)](https://polygon.technology)
[![Status: pre-mainnet](https://img.shields.io/badge/Status-pre--mainnet-orange.svg)](#audit-status)

> ⚠️ **Pre-mainnet, unaudited.** Do not deploy these contracts to a live
> mainnet with real funds. See [SECURITY.md](SECURITY.md) for the threat
> model and disclosure policy.

## Layout

| Path | Description |
| --- | --- |
| `src/MarketFactory.sol`, `ClovOracleAdapter.sol`, `MarketResolver.sol`, `MarketRewards.sol`, `ClovCommunityExecutor.sol` | First-party Clov contracts. |
| `src/ProxyWalletFactory.sol`, `ProxyWalletImplementation.sol` | EIP-1167 per-user proxy wallets deployed via CREATE2. |
| `src/exchange/` | CLOB exchange and supporting libraries — fork of [Polymarket CTF Exchange](https://github.com/Polymarket/ctf-exchange) (MIT). |
| `src/neg-risk/` | Multi-outcome support — fork of [Polymarket Neg-Risk CTF Adapter](https://github.com/Polymarket/neg-risk-ctf-adapter) (MIT). Adds `ClovNegRiskOracle` and `NegRiskCommunityRegistry` written for Clov's community-market lifecycle. |
| `src/vendor/` | Vendored third-party primitives (Gnosis Conditional Tokens, LGPL-3.0). |
| `src/interfaces/` | Public Solidity interfaces for first-party contracts. |
| `test/` | Foundry unit, fuzz (10 000 runs), and invariant (256 runs) tests. |
| `script/` | Deployment scripts (`Deploy.s.sol`, `DeployExchanges.s.sol`, `DeployMarketRewards.s.sol`, `DeployProxyWallet.s.sol`). |

Third-party attribution and license heterogeneity are documented in
[NOTICE](NOTICE).

## Clone

This repository uses git submodules for its Foundry dependencies. Always
clone with `--recurse-submodules`:

```bash
git clone --recurse-submodules https://github.com/ClovDao/clov-contracts.git
cd clov-contracts
```

If you already cloned without that flag:

```bash
git submodule update --init --recursive
```

## Build and test

```bash
forge build                          # compile
forge test                           # all suites (unit + fuzz + invariant)
forge test --match-contract MarketFactory
forge test --match-test test_createMarket
forge test -vvvv                     # verbose traces, useful for debugging reverts
forge fmt --check                    # style check (CI gate)
forge snapshot                       # gas snapshot
```

Solidity is pinned to `0.8.24` for first-party contracts; vendored forks
keep their upstream pragmas. Foundry config (`foundry.toml`) sets the
optimizer to 200 runs, fuzz runs to 10 000, and invariant runs to 256.

## Audit status

**Unaudited.** Do not deploy these contracts to a live mainnet with real
funds. A formal external audit is planned before any Polygon mainnet deploy.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch naming, commit format,
and the Solidity style/security checklist that gates every PR.

## Reporting vulnerabilities

See [SECURITY.md](SECURITY.md). Use [GitHub Private Vulnerability
Reporting](https://github.com/ClovDao/clov-contracts/security/advisories/new)
for sensitive findings — please don't open a public issue for security bugs.

## License

[MIT](LICENSE). Third-party files inherit alternative licenses (AGPL-3.0,
LGPL-3.0) — see [NOTICE](NOTICE) for the full breakdown.
