import "server-only";

import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

/**
 * Lazily loads the sponsor keypair from `SPONSOR_PRIVATE_KEY` (a bech32
 * `suiprivkey...` string). Cached for the lifetime of the server process.
 *
 * The sponsor is the funded localnet account that signs the gas leg of
 * `/api/sponsor`. It exists only on localnet — testnet/mainnet sponsorship
 * is handled by Enoki via the connected wallet, and the route refuses to
 * serve outside localnet regardless of env state.
 *
 * `fromSecretKey` accepts the bech32 string directly and throws if the
 * embedded schema is not ED25519.
 */
let cached: Ed25519Keypair | null = null;

export function sponsorKeypair(): Ed25519Keypair {
  if (cached) return cached;
  const key = process.env.SPONSOR_PRIVATE_KEY;
  if (!key || key.length === 0) {
    throw new Error(
      "SPONSOR_PRIVATE_KEY is not set. Re-run `pnpm bootstrap` on localnet " +
        "(which writes the sponsor key into .env.local) or set it manually.",
    );
  }
  cached = Ed25519Keypair.fromSecretKey(key);
  return cached;
}

export function sponsorAddress(): string {
  return sponsorKeypair().toSuiAddress();
}
