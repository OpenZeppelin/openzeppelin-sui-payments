import "server-only";

import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";

/**
 * Lazily loads the sponsor keypair from `SPONSOR_PRIVATE_KEY` (a bech32
 * `suiprivkey...` string). Cached for the lifetime of the server process.
 *
 * Throws on first access if the env var is missing — so any sponsored-tx
 * request fails fast and visibly instead of silently signing nothing.
 */
let cached: Ed25519Keypair | null = null;

export function sponsorKeypair(): Ed25519Keypair {
  if (cached) return cached;

  const key = process.env.SPONSOR_PRIVATE_KEY;
  if (!key || key.length === 0) {
    throw new Error(
      "SPONSOR_PRIVATE_KEY is not set. Generate one with " +
        "`sui keytool generate ed25519 --json` and fund it via `sui client faucet`.",
    );
  }

  const { schema, secretKey } = decodeSuiPrivateKey(key);
  if (schema !== "ED25519") {
    throw new Error(
      `Sponsor key schema is "${schema}"; only ED25519 is supported by /api/sponsor.`,
    );
  }

  cached = Ed25519Keypair.fromSecretKey(secretKey);
  return cached;
}

export function sponsorAddress(): string {
  return sponsorKeypair().toSuiAddress();
}
