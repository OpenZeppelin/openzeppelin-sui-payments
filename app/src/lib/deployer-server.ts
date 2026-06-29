import "server-only";

import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

/**
 * Lazily loads the deployer keypair from `DEPLOYER_PRIVATE_KEY` (a bech32
 * `suiprivkey...` string). Cached for the lifetime of the server process.
 *
 * The deployer is the account that ran `pnpm bootstrap` — it owns the
 * `TreasuryCap<STABLECOIN_MOCK>` and signs the stablecoin faucet PTB in
 * `/api/topup`. Keep this key restricted to demo / testnet networks; do NOT
 * deploy with it set to a real mainnet treasurer.
 *
 * `fromSecretKey` accepts the bech32 string directly and throws if the
 * embedded schema is not ED25519.
 */
let cached: Ed25519Keypair | null = null;

export function deployerKeypair(): Ed25519Keypair {
  if (cached) return cached;
  const key = process.env.DEPLOYER_PRIVATE_KEY;
  if (!key || key.length === 0) {
    throw new Error(
      "DEPLOYER_PRIVATE_KEY is not set. Re-run `pnpm bootstrap` (which writes " +
        "the deployer key into .env.local) or set it manually.",
    );
  }
  cached = Ed25519Keypair.fromSecretKey(key);
  return cached;
}

export function deployerAddress(): string {
  return deployerKeypair().toSuiAddress();
}
