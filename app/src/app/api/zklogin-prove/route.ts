import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { EnokiClientError } from "@mysten/enoki";
import { Ed25519PublicKey } from "@mysten/sui/keypairs/ed25519";

import { enokiClient } from "@/lib/enoki-server";

/** See `/api/zklogin-nonce/route.ts` for why this is testnet even on localnet. */
const ENOKI_NETWORK = "testnet" as const;

type ProveRequestBody = {
  /** Google-issued OpenID JWT (from the OAuth redirect fragment). */
  jwt: string;
  ephemeralPublicKey: string;
  maxEpoch: number;
  randomness: string;
};

type ProveResponseBody = {
  proofPoints: { a: string[]; b: string[][]; c: string[] };
  headerBase64: string;
  issBase64Details: { value: string; indexMod4: number };
  addressSeed: string;
  salt: string;
  address: string;
};

/**
 * POST /api/zklogin-prove
 *
 * Forwards the client's JWT + ephemeral pubkey + Enoki-issued nonce state to
 * Enoki's zkLogin ZKP endpoint. Enoki proves it against Mysten's prover using
 * their whitelisted audience list — that's how our own Google OAuth client_id
 * (which isn't on Mysten's public-prover allowlist) still gets accepted.
 *
 * Returns everything the client needs to build a `zkLoginSignature`: the ZK
 * proof, the JWT header + iss claims, the derived salt + address seed, and
 * the final Sui address.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  let body: ProveRequestBody;
  try {
    body = (await req.json()) as ProveRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }
  if (!body.jwt || !body.ephemeralPublicKey || !body.randomness || !body.maxEpoch) {
    return NextResponse.json(
      { error: "jwt, ephemeralPublicKey, randomness, maxEpoch are required" },
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
    const res = await enokiClient().createZkLoginZkp({
      network: ENOKI_NETWORK,
      jwt: body.jwt,
      ephemeralPublicKey,
      maxEpoch: body.maxEpoch,
      randomness: body.randomness,
    });
    // `getZkLogin` gives us the Sui address + salt for this JWT — Enoki keeps
    // the salt server-side, so the client never sees or manages it directly.
    const meta = await enokiClient().getZkLogin({ jwt: body.jwt });
    // Enoki types proofPoints as readonly Iterables; normalize to plain arrays
    // so the wire format matches `getZkLoginSignature`'s expected inputs shape.
    const response: ProveResponseBody = {
      proofPoints: {
        a: [...res.proofPoints.a],
        b: [...res.proofPoints.b].map((row) => [...row]),
        c: [...res.proofPoints.c],
      },
      headerBase64: res.headerBase64,
      issBase64Details: res.issBase64Details,
      addressSeed: res.addressSeed,
      salt: meta.salt,
      address: meta.address,
    };
    return NextResponse.json(response);
  } catch (err) {
    if (err instanceof EnokiClientError) {
      // Surface Enoki's own `code` + first-error message — much more useful
      // than the generic "status 400" the SDK's default toString gives.
      const first = err.errors[0];
      return NextResponse.json(
        {
          error: `enoki zkp failed (${err.status} ${err.code}): ${first?.message ?? err.message}`,
        },
        { status: 500 },
      );
    }
    return NextResponse.json(
      { error: `enoki zkp failed: ${err instanceof Error ? err.message : err}` },
      { status: 500 },
    );
  }
}
