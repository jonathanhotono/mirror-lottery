import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const LIMIT = 24_576;
const CONTRACTS = [
  "MirrorLottery",
  "MirrorSyndicate",
  "MirrorSyndicateFactory",
];

async function findArtifact(directory, fileName) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      const match = await findArtifact(path, fileName);
      if (match !== undefined) return match;
    } else if (entry.name === fileName) {
      return path;
    }
  }
  return undefined;
}

for (const contractName of CONTRACTS) {
  const artifactPath = await findArtifact(
    "artifacts",
    `${contractName}.json`,
  );
  if (artifactPath === undefined) {
    throw new Error(`Missing artifact for ${contractName}; compile first.`);
  }

  const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
  const size = (artifact.deployedBytecode.length - 2) / 2;
  console.log(`${contractName}: ${size} bytes`);
  if (size > LIMIT) {
    throw new Error(
      `${contractName} exceeds the EIP-170 limit by ${size - LIMIT} bytes.`,
    );
  }
}
