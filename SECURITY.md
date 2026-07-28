# Security policy

## Release status

Mirror Lottery v2 is testnet-only software. It is not approved for real-money
use, production custody, or mainnet deployment. “Audit-ready” in this
repository means that the code, threat model, tests, and review notes are
prepared for an independent auditor; it does not mean that an independent
audit has occurred.

## Reporting a vulnerability

Please use a private GitHub Security Advisory for this repository. Do not open
a public issue for a vulnerability that could put testnet users, future
deployments, keys, or infrastructure at risk.

Include:

- affected commit and contract/function;
- impact and required attacker capabilities;
- reproducible steps or a minimal proof of concept;
- suggested remediation, if known.

Do not test against a mainnet deployment or accounts you do not control.

## Security assumptions

- The configured payment token is genuine native USDC for the target chain and
  behaves as a standard ERC-20 without transfer fees or rebasing.
- The Chainlink VRF coordinator, key hash, subscription, and confirmation count
  match the target chain's official configuration.
- Default admin, guardian, treasury, draw manager, result publisher, and result
  verifier are secured independently. Publisher and verifier must not be the
  same signer or controlled by the same hot-wallet process.
- Frontends and indexers register winning tickets during the public
  registration window. An unregistered winning ticket cannot claim.
- Mirrored draws depend on off-chain source authenticity and two privileged
  attestations. They do not have the same trust model as VRF draws.
- Users understand that lottery access, age limits, consumer disclosures, and
  prize handling are jurisdiction-dependent.

## Defensive design

- immutable, non-upgradeable lottery core;
- delayed transfer of the default-admin role;
- role separation for draw operations, result publication, verification,
  emergency pause, and treasury;
- minimal VRF callback with no payout or participant loop;
- bounded ticket batches and pull-based claims/refunds;
- exact token balance-delta checks and `SafeERC20`;
- checks-effects-interactions plus `ReentrancyGuard` on token flows;
- per-draw state and accounting;
- no withdrawal function for active prize or rollover funds;
- cancellation only before a valid result is ready;
- claims and refunds remain available while purchasing is paused;
- mainnet deployment guard in the release script.

## Supported versions

Only the latest `2.0.0-testnet` line is under active security review. The
original proof-of-concept contracts are unsupported and must not be deployed.
