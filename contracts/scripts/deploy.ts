import { network } from "hardhat";
import { getAddress, isAddress, type Address } from "viem";

import { DEPLOYMENT_NETWORKS } from "../config/networks.js";

const { networkName, viem } = await network.connect();
const deploymentNetwork = DEPLOYMENT_NETWORKS[networkName];

if (deploymentNetwork === undefined) {
  throw new Error(
    `Unsupported deployment network "${networkName}". Use a configured Base or Arbitrum network.`,
  );
}
if (
  deploymentNetwork.mainnet &&
  process.env.MIRROR_MAINNET_DEPLOY_APPROVED !== "true"
) {
  throw new Error(
    "Mainnet is intentionally blocked. Complete an independent audit and legal review before enabling the approved release environment.",
  );
}

function requiredAddress(name: string): Address {
  const value = process.env[name];
  if (value === undefined || !isAddress(value)) {
    throw new Error(`${name} must be a valid EVM address.`);
  }
  return getAddress(value);
}

const subscriptionId = process.env.VRF_SUBSCRIPTION_ID;
if (subscriptionId === undefined || !/^[1-9]\d*$/.test(subscriptionId)) {
  throw new Error("VRF_SUBSCRIPTION_ID must be a positive integer.");
}

const roles = {
  admin: requiredAddress("ROLE_ADMIN"),
  drawManager: requiredAddress("ROLE_DRAW_MANAGER"),
  resultPublisher: requiredAddress("ROLE_RESULT_PUBLISHER"),
  resultVerifier: requiredAddress("ROLE_RESULT_VERIFIER"),
  guardian: requiredAddress("ROLE_GUARDIAN"),
  treasurer: requiredAddress("ROLE_TREASURER"),
  treasury: requiredAddress("TREASURY_ADDRESS"),
};

if (roles.resultPublisher === roles.resultVerifier) {
  throw new Error(
    "ROLE_RESULT_PUBLISHER and ROLE_RESULT_VERIFIER must be different addresses.",
  );
}

const lottery = await viem.deployContract("MirrorLottery", [
  deploymentNetwork.usdc,
  {
    coordinator: deploymentNetwork.vrfCoordinator,
    callbackGasLimit: 500_000,
    requestConfirmations: 3,
    subscriptionId: BigInt(subscriptionId),
    keyHash: deploymentNetwork.vrfKeyHash,
  },
  {
    mirrorChallengePeriod: 6 * 60 * 60,
    resultTimeout: 72 * 60 * 60,
    registrationPeriod: 7 * 24 * 60 * 60,
    claimPeriod: 90 * 24 * 60 * 60,
  },
  200,
  2 * 24 * 60 * 60,
  roles,
]);

const syndicateFactory = await viem.deployContract(
  "MirrorSyndicateFactory",
  [lottery.address],
);

console.log(
  JSON.stringify(
    {
      network: networkName,
      chainId: deploymentNetwork.chainId,
      lottery: lottery.address,
      syndicateFactory: syndicateFactory.address,
      usdc: deploymentNetwork.usdc,
      vrfCoordinator: deploymentNetwork.vrfCoordinator,
      explorer: deploymentNetwork.explorer,
    },
    null,
    2,
  ),
);
