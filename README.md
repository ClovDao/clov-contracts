# @clov/contracts

Foundry workspace for the Clov on-chain protocol.

## Layout

| Path | Description |
| --- | --- |
| `src/MarketFactory.sol`, `ClovOracleAdapter.sol`, `MarketResolver.sol`, `MarketRewards.sol`, `ClovCommunityExecutor.sol` | First-party Clov contracts. |
| `src/ProxyWalletFactory.sol`, `ProxyWalletImplementation.sol` | EIP-1167 per-user proxy wallets deployed via CREATE2. |
| `src/exchange/` | CLOB exchange and supporting libraries — fork of [Polymarket CTF Exchange](https://github.com/Polymarket/ctf-exchange) (MIT). |
| `src/neg-risk/` | Multi-outcome support — fork of Polymarket NegRisk (MIT). Includes `ClovNegRiskOracle` and `NegRiskCommunityRegistry` written for Clov's community-market lifecycle. |
| `src/vendor/` | Vendored third-party primitives (Gnosis Conditional Tokens). |
| `src/interfaces/` | Public Solidity interfaces for first-party contracts. |
| `test/` | Foundry unit, fuzz (10 000 runs), and invariant (256 runs) tests. |
| `script/` | Deployment scripts (`Deploy.s.sol`, `DeployExchanges.s.sol`). |

## Build and test

```bash
forge install                    # if you cloned without --recursive
forge build
forge test                       # all suites
forge test --match-contract MarketFactory
forge test -vvvv                 # verbose traces, useful for revert debugging
forge fmt --check                # style check (CI gate)
```

Solidity is pinned to `0.8.24` for first-party contracts; vendored forks
keep their upstream pragmas.

## Deployments

See the address table in the [root README](../../README.md#deployments) and
the runtime values exported from `@clov/sdk`.

## Audit status

**Unaudited.** Do not deploy these contracts to a live mainnet with real
funds. Any external integrations should be considered exploratory.

License: [MIT](../../LICENSE).
