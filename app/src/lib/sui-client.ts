import { getFullnodeUrl } from "@mysten/sui/client";

export type SuiNetwork = "devnet" | "testnet" | "mainnet" | "localnet";

export const NETWORK: SuiNetwork =
  (process.env.NEXT_PUBLIC_SUI_NETWORK as SuiNetwork) ?? "testnet";

export const networkConfig = {
  devnet: { url: getFullnodeUrl("devnet") },
  testnet: { url: getFullnodeUrl("testnet") },
  mainnet: { url: getFullnodeUrl("mainnet") },
  localnet: { url: getFullnodeUrl("localnet") },
} as const;
