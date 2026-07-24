import hardhatToolboxViem from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";
import { fileURLToPath } from "node:url";

const compiler = {
  version: "0.8.36",
  path: fileURLToPath(
    new URL("./node_modules/solc/soljson.js", import.meta.url),
  ),
  preferWasm: true,
  settings: {
    evmVersion: "cancun",
    optimizer: {
      enabled: true,
      runs: 500,
    },
    viaIR: true,
  },
} as const;

export default defineConfig({
  plugins: [hardhatToolboxViem],
  paths: {
    sources: "./src",
    tests: {
      nodejs: "./test",
    },
  },
  solidity: {
    profiles: {
      default: compiler,
      production: compiler,
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    baseSepolia: {
      type: "http",
      chainType: "op",
      chainId: 84532,
      url: configVariable("BASE_SEPOLIA_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
    arbitrumSepolia: {
      type: "http",
      chainType: "generic",
      chainId: 421614,
      url: configVariable("ARBITRUM_SEPOLIA_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
    base: {
      type: "http",
      chainType: "op",
      chainId: 8453,
      url: configVariable("BASE_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
    arbitrum: {
      type: "http",
      chainType: "generic",
      chainId: 42161,
      url: configVariable("ARBITRUM_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
  },
});
