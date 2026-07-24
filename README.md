# Mirror Lottery

Mirror Lottery is a testnet-first lottery protocol and Electric Arcade web app
for Base and Arbitrum. It supports two deliberately distinct result models:

- fully on-chain draws using Chainlink VRF v2.5-compatible requests;
- mirrored official results using separate publisher and verifier roles plus a
  public challenge delay.

It also includes immutable, single-draw syndicates with fixed-price shares,
captain spending constrained to lottery tickets, and pull-based pro-rata prize
distribution.

> **Testnet only.** This repository has received an internal security review,
> automated tests, linting, and dependency checks. It has **not** received an
> independent smart-contract audit. Mainnet deployment is blocked until an
> external audit, remediation, multisig ceremony, legal review, and testnet
> soak are complete.

## What changed from the proof of concept

The 2023 prototype relied on an owner-selected winner, unchecked token
transfers, payout loops over every participant, shared accounting across draws,
and incomplete frontend sources. The v2 testnet rebuild replaces those paths
with:

- Solidity `0.8.36`, OpenZeppelin Contracts `5.6.1`, Hardhat `3.11.1`, and
  viem `2.55.8`, all exactly pinned;
- an immutable, non-upgradeable core;
- role separation with delayed default-admin transfer;
- `SafeERC20`, exact balance-delta checks, reentrancy protection, and pausing;
- per-draw accounting, bounded batches, pull claims, refunds, and rollover;
- a minimal VRF callback that stores one random word and transfers no funds;
- dual-attested mirrored results with a challenge window;
- explicit timeout cancellation before a valid result is ready;
- fixed-price syndicate shares and constrained captain spending;
- a responsive Electric Arcade product experience.

## Repository

```text
app/                    Electric Arcade web app
public/                 Optimized visual assets
contracts/src/          Lottery, syndicate, and minimal VRF interface
contracts/test/         Hardhat 3 + node:test integration suite
contracts/config/       Base and Arbitrum deployment constants
contracts/scripts/      Guarded deployment and bytecode-size checks
docs/                   Threat model and release procedure
AUDIT.md                Internal review report and unresolved release gates
SECURITY.md             Disclosure policy and security assumptions
```

## Local development

Requirements: Node.js `>=22.13.0`.

```bash
npm ci
npm run dev
```

Contract development:

```bash
cd contracts
npm ci
npm run verify
```

The contract compiler is the exact npm-pinned `solc` build, so compilation does
not depend on downloading an unpinned compiler binary.

## Pilot networks

The first release targets Base Sepolia and Arbitrum Sepolia. Network constants
are in `contracts/config/networks.ts`.

| Network | Chain ID | Circle test USDC | Chainlink VRF v2.5 coordinator |
| --- | ---: | --- | --- |
| Base Sepolia | 84532 | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | `0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE` |
| Arbitrum Sepolia | 421614 | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` | `0x5CE8D5A2BC84beb22a398CCA51996F7930313D61` |

Circle test USDC and native testnet tokens have no financial value.

## Deployment

Populate the role and VRF variables described in
`contracts/.env.example`, preferably with Hardhat's encrypted keystore, fund
the VRF subscription, and run one of:

```bash
npm --prefix contracts run deploy:base-sepolia
npm --prefix contracts run deploy:arbitrum-sepolia
```

Publisher and verifier addresses must differ. Use multisigs or operationally
separate keys for privileged roles. Mainnet commands are not provided and the
deployment script refuses mainnet unless the audited release environment sets
its explicit gate.

Read [SECURITY.md](SECURITY.md), [AUDIT.md](AUDIT.md), and
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) before any deployment.

## License

MIT
