# Testnet deployment runbook

## Before deployment

1. Run `npm --prefix contracts run verify`.
2. Confirm the exact Circle USDC, Chainlink VRF coordinator, and key hash in
   `contracts/config/networks.ts` against official documentation.
3. Create and fund a VRF v2.5 subscription and authorize the deployed lottery
   as a consumer.
4. Assign operationally separate role addresses. Use a multisig for default
   admin and treasury. Publisher and verifier must be separate signers.
5. Store the deployer private key with Hardhat keystore or the approved secret
   manager; never commit an `.env` file.
6. Record compiler version, optimizer settings, commit SHA, role owners, VRF
   subscription, and intended constructor parameters.

## Deployment

Use the testnet scripts from the repository root:

```bash
npm --prefix contracts run deploy:base-sepolia
npm --prefix contracts run deploy:arbitrum-sepolia
```

The script deploys the immutable lottery and syndicate factory. It does not
create a draw or fund a prize pool.

## After deployment

1. Verify source and constructor arguments on the chain explorer.
2. Add the lottery as an authorized VRF subscription consumer.
3. Confirm every role and the treasury address from on-chain reads.
4. Create a low-value VRF draw and exercise purchase, result, registration,
   settlement, claim, timeout, and refund paths.
5. Create a mirrored draw and verify publish, confirm, challenge, and re-propose
   behavior.
6. Create a syndicate and verify share purchase, ticket-only spending,
   permissionless registration/claim, and pro-rata distribution.
7. Publish addresses and ABIs only after comparing deployed bytecode to the
   reviewed build.

## Mainnet

Mainnet is not authorized. The deployment script rejects it unless the audited
release environment sets `MIRROR_MAINNET_DEPLOY_APPROVED=true`. That flag is a
last mechanical gate, not evidence that the audit or legal requirements were
met.
