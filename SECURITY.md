# Security Policy

Clov is a decentralized sports prediction market on Polygon PoS. This
repository contains the on-chain protocol: a Polymarket-style CLOB over
Gnosis Conditional Tokens, with UMA Optimistic Oracle V3 for dispute
resolution and a creator-funded community-market lifecycle (50 USDC bond,
48-hour challenge window).

This document describes how to disclose vulnerabilities responsibly and
what the current security posture of the protocol looks like.

## Supported Versions

Clov is **pre-mainnet**. There is no semantic versioning yet and no tagged
releases. Only the `main` branch is actively maintained and receives
security updates.

| Branch / Version | Supported |
| --- | --- |
| `main` | Yes |
| Feature branches | No |
| Tagged releases | None exist yet |

Once Clov ships to Polygon mainnet, this table will be replaced with a
real versioned support matrix.

## Reporting a Vulnerability

Please report security vulnerabilities **privately**. Do not open a public
GitHub issue, draft pull request, or discussion thread for security-sensitive
findings.

- **Preferred channel:** [GitHub Private Vulnerability Reporting](https://github.com/ClovDao/clov-contracts/security/advisories/new)
  — open a draft security advisory directly from the repository's Security tab.
- **PGP:** A PGP public key is not yet published. If you require encrypted
  communication, mention this in the advisory and a key will be shared on
  a case-by-case basis.

### What to include

- A clear description of the vulnerability and its impact.
- Steps to reproduce, including transaction hashes or proof-of-concept code.
- The commit hash or tag the report targets.
- Your assessment of severity and any suggested mitigation.
- Whether you wish to be credited publicly upon disclosure.

### Response targets

- **Acknowledgment:** within 24 hours of receipt.
- **Initial triage and severity assessment:** within 48 hours.
- **Status updates:** at minimum every 7 days until resolution.

These are targets, not guarantees. Pre-mainnet, response times should
generally be faster than the upper bound.

### Coordinated disclosure

Default disclosure window is **90 days** from initial report. If a fix
requires a redeploy, migration, or audit re-engagement, the window can be
extended by mutual agreement. Active in-the-wild exploitation overrides
the window — we will move to disclose and patch as quickly as possible.

## Scope

### In scope

- **First-party Clov contracts** in `src/`:
  - `MarketFactory`, `ClovOracleAdapter`, `MarketResolver`, `MarketRewards`
  - `ClovCommunityExecutor`, `NegRiskCommunityRegistry`, `ClovNegRiskOracle`
  - `ProxyWalletFactory`, `ProxyWalletImplementation`
- **Deploy scripts** in `script/` — particularly the role-handoff and
  Timelock initialization paths.
- **Modifications** the Clov team made to the upstream Polymarket forks
  under `src/exchange/` and `src/neg-risk/`. Verbatim upstream bugs should
  be reported to Polymarket, not here.

### Out of scope

- Bugs in upstream dependencies (Polymarket CTF Exchange, Gnosis Conditional
  Tokens, OpenZeppelin, UMA OOV3, Solady, Solmate). Report those to the
  relevant project.
- Findings that depend on a compromised end-user device or wallet extension.
- Best-practice findings without a demonstrable exploit path.
- Issues already known and tracked in public GitHub issues.

The off-chain backend, frontend, and infrastructure are tracked in a
separate, private repository. If you find a cross-cutting issue (e.g., the
backend signs a CLOB order in a way that exploits a contract bug), report
it through this advisory channel — we will route it appropriately.

## Threat Model

The following actors are part of Clov's trusted computing base.

### Smart contract owner

Currently a single EOA controlled by the maintainer. Migrating to a Gnosis
Safe multisig with a Timelock prior to Polygon mainnet deploy. Privileges:

- Pause and unpause markets.
- Update protocol fees within the bounds enforced on-chain.
- Set the oracle adapter address.
- Set the merkle root for `MarketRewards` distributions.

Pre-mainnet, owner key compromise is the single largest risk.

### UMA Optimistic Oracle V3

Ground truth for market resolution. We rely on UMA's economic security
model (bonded assertions, dispute window, DVM voting). If UMA's security
model fails, all Clov assertion-based markets fail with it. We do not
maintain an independent fallback oracle.

### Relayer (off-chain)

Signs and submits matched CLOB orders to the on-chain CTF Exchange.
Compromise of the relayer key allows forged match submissions, but the
on-chain mitigation is EIP-712 signature verification: the exchange
executes matches only against orders signed by the actual maker and taker.
The relayer cannot fabricate user signatures.

## Known Limitations and Intentional Design Choices

### Pre-mainnet, unaudited

Smart contracts have **not been audited** by an external firm. **Do not
deploy with real funds.** A formal audit is planned before any Polygon
mainnet deploy and is a hard gate on the release.

### Community-market bond size

Community markets require a 50 USDC creator bond and a 48-hour challenge
window. We acknowledge that 50 USDC may be insufficient collateral against
a sufficiently motivated, high-stakes manipulator. We accept this tradeoff
for early-stage UX and will revisit once we have real-world abuse data.

### Mixed licenses

Some files inherit AGPL-3.0-only or LGPL-3.0 from upstream forks
(documented in [NOTICE](NOTICE)). Use of those specific files is governed
by their original licenses, not the MIT umbrella. This is not a security
issue but is worth flagging for downstream integrators.

## Bug Bounty

Clov does **not** currently operate a formal bug bounty program. A program
on Immunefi (or comparable) is planned alongside the Polygon mainnet
deploy.

Until then:

- Pre-mainnet white-hat reports are genuinely appreciated.
- With your consent, valid disclosures will be credited publicly in the
  relevant release notes and, when the bounty program launches, in a
  dedicated acknowledgments page.
- Discretionary rewards may be offered for high-impact findings even
  before the formal program exists, at the maintainer's discretion.

## Safe Harbor

Clov will not pursue legal action against researchers who:

- Make a good-faith effort to comply with this policy.
- Avoid privacy violations, destruction of data, and disruption of the
  service for other users.
- Do not exploit vulnerabilities beyond the minimum necessary to confirm
  their existence.
- Give us a reasonable opportunity to remediate before public disclosure.

If in doubt about whether a particular test is in good faith, ask first
through the advisory channel.
