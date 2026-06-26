import { getFullnodeUrl } from "@mysten/sui/client";

export type SuiNetwork = "devnet" | "testnet" | "mainnet" | "localnet";

const SUPPORTED_NETWORKS: readonly SuiNetwork[] = [
  "devnet",
  "testnet",
  "mainnet",
  "localnet",
];

// Validate at module load so an invalid or missing `NEXT_PUBLIC_SUI_NETWORK`
// fails fast with a useful message. Without this, a typo silently produced
// `undefined.url` in downstream `networkConfig[NETWORK].url` lookups, and an
// omitted value silently pointed the app at testnet — both can quietly send
// transactions to the wrong chain.
const networkEnv = process.env.NEXT_PUBLIC_SUI_NETWORK;
if (!networkEnv || !(SUPPORTED_NETWORKS as readonly string[]).includes(networkEnv)) {
  throw new Error(
    `NEXT_PUBLIC_SUI_NETWORK must be one of: ${SUPPORTED_NETWORKS.join(", ")} ` +
      `(got ${JSON.stringify(networkEnv)})`,
  );
}

export const NETWORK: SuiNetwork = networkEnv as SuiNetwork;

export const networkConfig = {
  devnet: { url: getFullnodeUrl("devnet") },
  testnet: { url: getFullnodeUrl("testnet") },
  mainnet: { url: getFullnodeUrl("mainnet") },
  localnet: { url: getFullnodeUrl("localnet") },
} as const;
