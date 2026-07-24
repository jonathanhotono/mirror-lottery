# Internal security review — v2.0.0-testnet

Review date: 2026-07-24

## Status

**Internal review complete for the current testnet candidate. Independent audit
not yet performed. Mainnet release blocked.**

This document records engineering review and automated verification. It is not
an audit opinion, certification, guarantee of correctness, or substitute for an
independent smart-contract audit.

## Scope

- `contracts/src/MirrorLottery.sol`
- `contracts/src/MirrorSyndicate.sol`
- `contracts/src/interfaces/IVrfCoordinatorV2Plus.sol`
- deployment configuration and role gates
- tests in `contracts/test/MirrorLottery.ts`

Mocks, the marketing UI, third-party infrastructure, off-chain mirror-source
operators, private-key controls, and legal compliance are outside the
smart-contract review scope.

## Verification performed

- exact Solidity `0.8.36` compilation with optimizer, IR pipeline, and Cancun
  EVM target;
- seven integration tests covering authorization, malformed entries,
  fee-on-transfer rejection, VRF callback/finalization, mirror dual
  attestation/challenge, tier accounting, pausing, fee withdrawals,
  cancellation/refunds, and syndicate distribution;
- Solhint `6.2.3` with zero findings under the repository's security-focused
  rule set;
- production dependency audit with zero known vulnerabilities;
- deployed bytecode checks against the EIP-170 limit:
  - `MirrorLottery`: 19,589 bytes;
  - `MirrorSyndicate`: 6,222 bytes;
  - `MirrorSyndicateFactory`: 8,365 bytes.

The current Hardhat/solc development toolchain has upstream-only advisories in
tools that do not enter deployed bytecode. They are tracked as release hygiene
and must be re-evaluated when patched releases are available.

## Findings and disposition

| ID | Severity | Original condition | Disposition |
| --- | --- | --- | --- |
| ML-01 | Critical | Owner could choose a winner | Removed. VRF or dual-attested mirrored result only. |
| ML-02 | Critical | Settlement looped over all participants and transferred funds | Removed. Fixed-size settlement plus pull claims/refunds. |
| ML-03 | High | ERC-20 return values and received amounts were unchecked | Resolved with `SafeERC20` and exact balance-delta checks. |
| ML-04 | High | Prize division could misallocate funds | Resolved with fixed basis-point tiers, per-winner amounts, and explicit remainder rollover. |
| ML-05 | High | Funds and participants were not isolated per draw | Resolved with explicit per-draw state and accounting. |
| ML-06 | High | Administrator could withdraw funds without active-pool separation | Resolved. Only accrued protocol fees can be withdrawn. |
| ML-07 | Medium | Duplicate or out-of-range numbers were accepted | Resolved with sorted, unique, bounded packed-number validation. |
| ML-08 | Medium | Late cancellation could be selected after a valid result was visible | Resolved. Cancellation is unavailable once a result reaches `RESULT_READY`. |
| ML-09 | Medium | Full Chainlink npm package pulled unrelated vulnerable legacy dependencies | Resolved by keeping only the official-compatible VRF v2.5 request ABI locally. |
| ML-10 | Informational | Mirrored draws require trusted off-chain operators | Accepted and explicitly disclosed; separate publisher/verifier plus challenge delay. |
| ML-11 | Informational | Winning tickets must be registered before settlement | Accepted product rule; registration is permissionless and should be automated by multiple indexers. |
| ML-12 | Informational | Sub-unit distribution dust can remain in a syndicate | Accepted; dust is less than one token base unit per share and is publicly visible. |

## Residual risks

- Chainlink coordinator or subscription misconfiguration can stall VRF draws.
- Colluding or compromised mirror attestors can submit a false external result
  unless the guardian challenges it before finalization.
- Pausing stops new purchasing and result operations but intentionally does not
  stop claims or refunds.
- A captain controls number selection for a syndicate, although pooled funds
  cannot be withdrawn or spent outside the target draw.
- USDC blacklist/freeze behavior can affect transfers independently of this
  protocol.
- Registration and claim windows create liveness requirements for users and
  indexers.
- The code has not yet received fuzzing, formal verification, economic-model
  review, or independent auditor validation.

## Mainnet release blockers

1. Independent audit by a qualified smart-contract security firm.
2. Remediation and auditor confirmation for every accepted finding.
3. Stateful invariant/fuzz campaign covering solvency and lifecycle
   transitions.
4. Base Sepolia and Arbitrum Sepolia soak with live VRF subscriptions.
5. Multisig/timelock setup, signer separation, runbooks, and incident drill.
6. Verified source publication and bytecode/config comparison on both chains.
7. Legal, licensing, consumer-protection, age-gating, sanctions, tax, and
   responsible-play review for every launch jurisdiction.

Do not remove the mainnet deployment gate until all seven items are documented
and approved.
