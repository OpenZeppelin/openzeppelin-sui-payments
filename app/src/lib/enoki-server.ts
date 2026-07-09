import "server-only";

import { EnokiClient } from "@mysten/enoki";

/**
 * Lazily instantiates the Enoki server client from `ENOKI_PRIVATE_API_KEY`.
 * Cached for the lifetime of the server process.
 *
 * Consumed by the sponsored-tx routes:
 *   - `/api/enoki-sponsor`  → `createSponsoredTransaction`
 *   - `/api/enoki-execute`  → `executeSponsoredTransaction`
 *
 * On testnet/mainnet an Enoki-registered wallet triggers this pair to get a
 * sponsor-signed gas leg for user txs. Enoki charges sponsorship against the
 * app registered to this API key, subject to the dashboard's
 * `allowedMoveCallTargets` allowlist.
 */
let cached: EnokiClient | null = null;

export function enokiClient(): EnokiClient {
  if (cached) return cached;
  const apiKey = process.env.ENOKI_PRIVATE_API_KEY;
  if (!apiKey || apiKey.length === 0) {
    throw new Error(
      "ENOKI_PRIVATE_API_KEY is not set. Populate it from the Enoki dashboard " +
        "(server-only, `enoki_private_...` prefix).",
    );
  }
  cached = new EnokiClient({ apiKey });
  return cached;
}
