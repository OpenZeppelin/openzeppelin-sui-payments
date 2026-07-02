import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { EnokiClientError } from "@mysten/enoki";

import { enokiClient } from "@/lib/enoki-server";
import { NETWORK } from "@/lib/sui-client";

type ExecuteRequestBody = {
  /** Digest from `/api/enoki-sponsor` — Enoki uses it to look up the cached sponsor sig. */
  digest: string;
  /** Wallet's signature over the bytes returned by `/api/enoki-sponsor`. */
  signature: string;
};

type ExecuteResponseBody = {
  digest: string;
};

/**
 * POST /api/enoki-execute
 *
 * Phase 2 of the Enoki sponsorship flow: hand Enoki the wallet's signature so
 * it can combine with its cached sponsor sig and submit to chain. Returns the
 * on-chain digest for the caller to await.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  if (NETWORK === "localnet") {
    return NextResponse.json(
      { error: "/api/enoki-execute is disabled on localnet." },
      { status: 410 },
    );
  }

  let body: ExecuteRequestBody;
  try {
    body = (await req.json()) as ExecuteRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }
  if (!body.digest || !body.signature) {
    return NextResponse.json(
      { error: "digest and signature are required" },
      { status: 400 },
    );
  }

  try {
    const res = await enokiClient().executeSponsoredTransaction({
      digest: body.digest,
      signature: body.signature,
    });
    const response: ExecuteResponseBody = { digest: res.digest };
    return NextResponse.json(response);
  } catch (err) {
    if (err instanceof EnokiClientError) {
      const first = err.errors[0];
      return NextResponse.json(
        {
          error: `enoki execute failed (${err.status} ${err.code}): ${first?.message ?? err.message}`,
        },
        { status: 500 },
      );
    }
    return NextResponse.json(
      { error: `enoki execute failed: ${err instanceof Error ? err.message : err}` },
      { status: 500 },
    );
  }
}
