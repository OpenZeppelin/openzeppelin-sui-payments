import "server-only";

import { EnokiClient } from "@mysten/enoki";

/**
 * Lazily instantiates the Enoki server client from `ENOKI_PRIVATE_API_KEY`.
 * Cached for the lifetime of the server process.
 *
 * Only used by the zkLogin proxy routes (`/api/zklogin-nonce`, `/api/zklogin-prove`)
 * — Enoki's server backend has the standing whitelist arrangement with Mysten's
 * zkLogin prover that lets our own Google OAuth client_id be accepted (as long
 * as it's registered in the Enoki dashboard).
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
