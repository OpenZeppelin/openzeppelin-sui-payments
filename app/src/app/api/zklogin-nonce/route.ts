import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { Ed25519PublicKey } from "@mysten/sui/keypairs/ed25519";

import { enokiClient } from "@/lib/enoki-server";

/**
 * The Enoki network binding — see `ENOKI_NETWORK` below. Enoki's own SDK
 * refuses `"localnet"` (their backend can't reach `localhost` to fetch epoch
 * data), so we call Enoki against testnet even when the app targets localnet.
 * The Groth16 proof itself is chain-agnostic; the only chain-bound value is
 * `maxEpoch`, which testnet's epoch (~600+) puts well above localnet's (0) —
 * so a testnet-issued proof stays valid on localnet indefinitely.
 */
const ENOKI_NETWORK = "testnet" as const;

type NonceRequestBody = {
  /** Ephemeral Ed25519 public key, sui-serialized (schema flag + 32 bytes, base64). */
  ephemeralPublicKey: string;
};

type NonceResponseBody = {
  nonce: string;
  randomness: string;
  maxEpoch: number;
};

/**
 * POST /api/zklogin-nonce
 *
 * Forwards the client's ephemeral pubkey to Enoki's zkLogin nonce endpoint.
 * Enoki returns the nonce (JWT commitment) + randomness + maxEpoch that the
 * client will use for the OAuth redirect. We echo the subset the client needs
 * to reconstruct pre-OAuth state.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  let body: NonceRequestBody;
  try {
    body = (await req.json()) as NonceRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }
  if (!body.ephemeralPublicKey) {
    return NextResponse.json(
      { error: "ephemeralPublicKey is required" },
      { status: 400 },
    );
  }

  let ephemeralPublicKey: Ed25519PublicKey;
  try {
    ephemeralPublicKey = new Ed25519PublicKey(body.ephemeralPublicKey);
  } catch (err) {
    return NextResponse.json(
      { error: `invalid ephemeralPublicKey: ${err instanceof Error ? err.message : err}` },
      { status: 400 },
    );
  }

  try {
    const res = await enokiClient().createZkLoginNonce({
      network: ENOKI_NETWORK,
      ephemeralPublicKey,
    });
    const response: NonceResponseBody = {
      nonce: res.nonce,
      randomness: res.randomness,
      maxEpoch: res.maxEpoch,
    };
    return NextResponse.json(response);
  } catch (err) {
    return NextResponse.json(
      { error: `enoki nonce failed: ${err instanceof Error ? err.message : err}` },
      { status: 500 },
    );
  }
}
