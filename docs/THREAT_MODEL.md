# Threat model

## Assets

- ticket-sale USDC;
- sponsored prize and rollover USDC;
- accrued protocol fees;
- correct draw result and prize accounting;
- syndicate contributions and prize distributions;
- privileged role keys and VRF subscription.

## Trust boundaries

```text
Player wallet
  ├─ standard USDC transfer ──> MirrorLottery
  ├─ ticket ownership ────────> bounded claim/refund
  └─ shares ──────────────────> MirrorSyndicate
                                  └─ ticket-only spend ──> MirrorLottery

VRF draw: Chainlink coordinator ──> store random word ──> anyone finalizes

Mirror draw: publisher ──> verifier ──> challenge delay ──> anyone finalizes
                              guardian may invalidate during delay
```

VRF and mirrored draws are not equivalent. A VRF result depends on the
configured oracle network and subscription. A mirrored result additionally
depends on the authenticity of an external source and non-collusion between
publisher and verifier.

## Primary abuse cases

- forged randomness callback: rejected unless caller is the immutable
  coordinator;
- outcome-dependent cancellation: blocked after `RESULT_READY`;
- reentrancy during token transfers: state is updated before transfer and
  token-flow entrypoints are guarded;
- transfer-fee/rebase insolvency: incoming balance must increase by the exact
  quoted amount;
- denial of service through large participant lists: no full-participant
  settlement or payout loop;
- role compromise: powers are split; active prize funds have no admin withdrawal
  path; claims/refunds remain live while paused;
- mirror collusion: mitigated, not eliminated, by separate roles, source hash,
  challenge delay, guardian, and public events;
- captain theft: syndicate has no arbitrary withdrawal and can call only the
  target lottery draw when purchasing tickets;
- accounting bleed between draws: each draw tracks sales, sponsor pool,
  winners, claims, fee, cancellation, and deadlines separately.

## Invariants

- payment-token outflows are prizes, refunds, or already-accrued protocol fees;
- a ticket can be claimed once or refunded once, never both in reachable states;
- a draw result is immutable after registration opens;
- tier percentages sum to 10,000 basis points at draw creation;
- settlement work is constant in the number of tiers;
- ticket registration and transfer batches are capped at 50;
- rollover can be allocated only once and cannot be withdrawn;
- a syndicate member's distribution equals owned shares times the finalized
  per-share amount.
