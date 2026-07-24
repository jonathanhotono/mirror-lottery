import type { Address, Hash } from "viem";

export type DeploymentNetwork = {
  chainId: number;
  mainnet: boolean;
  usdc: Address;
  vrfCoordinator: Address;
  vrfKeyHash: Hash;
  explorer: string;
};

export const DEPLOYMENT_NETWORKS: Record<string, DeploymentNetwork> = {
  baseSepolia: {
    chainId: 84532,
    mainnet: false,
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    vrfCoordinator: "0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE",
    vrfKeyHash:
      "0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71",
    explorer: "https://sepolia.basescan.org",
  },
  arbitrumSepolia: {
    chainId: 421614,
    mainnet: false,
    usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
    vrfCoordinator: "0x5CE8D5A2BC84beb22a398CCA51996F7930313D61",
    vrfKeyHash:
      "0x1770bdc7eec7771f7ba4ffd640f34260d7f095b79c92d34a5b2551d6f6cfd2be",
    explorer: "https://sepolia.arbiscan.io",
  },
  base: {
    chainId: 8453,
    mainnet: true,
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    vrfCoordinator: "0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634",
    vrfKeyHash:
      "0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab",
    explorer: "https://basescan.org",
  },
  arbitrum: {
    chainId: 42161,
    mainnet: true,
    usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    vrfCoordinator: "0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e",
    vrfKeyHash:
      "0x9e9e46732b32662b9adc6f3abdf6c5e926a666d174a4d6b8e39c4cca76a38897",
    explorer: "https://arbiscan.io",
  },
};
