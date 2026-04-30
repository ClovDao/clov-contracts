# Contributing to clov-contracts

Thanks for your interest. This document describes the workflow, conventions,
and quality bar for changes to the Clov on-chain protocol.

## Workflow

1. Open an issue first for non-trivial changes (new features, architectural
   shifts). For obvious bug fixes you can skip this and open a PR directly.
2. Branch from `main`. Branch names are descriptive of the change, not of
   internal phasing or sprint identifiers. Examples:
   - `fix/challenge-deadline-monotonicity`
   - `feat/multi-outcome-resolution`
   - `chore/upgrade-foundry`
3. Make focused commits. One logical change per commit. Squash trivial
   fix-ups locally before pushing.
4. Open a PR against `main`. CI must pass before review.
5. After approval, the PR is squash-merged. The squashed commit message
   should follow the conventional commits format below.

## Commit format

```
type(scope): description
```

| Field | Allowed values |
| --- | --- |
| `type` | `feat`, `fix`, `test`, `chore`, `docs`, `refactor`, `perf`, `ci` |
| `scope` | `contracts`, `exchange`, `neg-risk`, `oracle`, `rewards`, `proxy-wallet`, `deploy`, `deps` |
| `description` | English, imperative mood, no trailing period, max 72 chars |

The optional body explains the technical *what* and *why*. Do not include:

- Co-authored-by trailers identifying AI assistants.
- Business motivation, revenue rationale, competitive comparisons.
- Internal sprint, phase, or task identifiers.

Examples:

```
fix(contracts): enforce challenge deadline monotonicity
test(contracts): add fuzz coverage for escrow conservation
ci: add slither static analysis on every PR
```

## Pull request structure

Required sections:

- **What** — a technical summary of the change.
- **Why** — the technical reason. No business motivation.
- **Testing** — which tests cover the change, or how to validate manually.
- **Breaking changes** — any consumer impact.
- **Gas impact** — if `forge snapshot` shows non-trivial drift, explain it.

Keep the PR description focused on the technical surface. Skip
competitor comparisons, product metrics, and roadmap context.

## Solidity style

- `forge fmt` is the source of truth. CI runs `forge fmt --check`.
- 120-character line limit, 4-space tabs, bracket spacing on (configured in
  `foundry.toml`).
- All external and public functions have natspec (`@notice`, `@param`,
  `@return`).
- Internal functions and parameters use a leading underscore:
  `_functionName`, `_paramName`.
- External contracts inherit from their corresponding interface in
  `src/interfaces/`.
- Custom errors are preferred over `require` strings. Define them at the
  top of the contract (or in the relevant interface) with names that read as
  the failure mode: `NotEligibleToEscalate(address)`, not `Error1`.
- Events MUST be emitted on every critical state mutation. The event signature
  should let an off-chain indexer reconstruct the action without reading
  storage.

## Security checklist

Run this checklist before opening a PR. CI catches most of it but not all.

### Critical

- No reentrancy without an explicit guard (`ReentrancyGuard` or strict
  checks-effects-interactions).
- Access control is correct on every external mutation. No `public` setters
  without `onlyOwner` / `onlyRole`.
- Solidity ^0.8 overflow protection is sufficient — if a function disables
  it via `unchecked`, justify the bound in a comment.
- No `tx.origin` for authentication. Use `msg.sender`.
- No `delegatecall` to arbitrary or user-controllable addresses.
- Events are emitted on every state-mutating external/public function.

### Code quality

- `forge fmt --check` passes.
- `forge build --sizes` produces no contract over the EIP-170 24 KiB limit
  unless you have a documented strategy (proxy, library, etc.).
- `forge test` passes. Add tests for the new behavior — fuzzing where the
  input space is non-trivial, invariants where there is a global property
  to preserve.
- `forge snapshot --check` either passes or the PR description explains the
  drift.

### Sensitive information

This is an open-source repository. The code is public; the business model
should not be. Do not include in commit messages, PR descriptions, comments,
or natspec:

- Revenue model details (fee splits, commission structure).
- Strategic motivation behind decisions.
- Future roadmap or unreleased features.
- Specific competitive mechanics not enforced on-chain.
- Partner names or integrations under negotiation.

If in doubt, ask in the PR thread before merging.

## Repo structure

- New first-party contracts go in `src/`.
- New tests go in `test/`: `*.t.sol` for unit, `*.fuzz.t.sol` for fuzz,
  `test/invariants/` for invariants.
- Deploy scripts go in `script/`. Use Forge's `vm.envUint("PRIVATE_KEY")`
  pattern — never hardcode keys.
- Foundry dependencies are git submodules under `lib/`. Do not vendor a
  dependency by copying it into `src/` unless there is a clear reason
  documented in NOTICE.
- Do not commit: `out/`, `cache/`, `broadcast/`, `.env`, or any Foundry
  build artifact. The repo's `.gitignore` enforces this.

## Local git config

If you cloned this repo for the first time, set your local git identity to
the same identity you use on GitHub for this project:

```bash
git config user.name "<your-github-handle>"
git config user.email "<your-github-noreply-email>"
```

This is per-repo and prevents your global personal identity from leaking
into commit metadata.
