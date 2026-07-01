import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { EnokiClientError } from "@mysten/enoki";

import { enokiClient } from "@/lib/enoki-server";
import { NETWORK } from "@/lib/sui-client";

type SponsorRequestBody = {
  /** Base64 `TransactionKind` bytes (built with `onlyTransactionKind: true`). */
  txKindBytes: string;
  /** Sender address (the zkLogin address that will co-sign). */
  sender: string;
};

type SponsorResponseBody = {
  /** Base64 `TransactionData` bytes the wallet must sign. */
  bytes: string;
  /** Enoki's tracking digest — needed by `/api/enoki-execute`. */
  digest: string;
};

/** Enoki's networks; localnet is not supported. */
function enokiNetwork(): "testnet" | "mainnet" {
  if (NETWORK === "testnet") return "testnet";
  if (NETWORK === "mainnet") return "mainnet";
  throw new Error(`enoki does not support NETWORK=${NETWORK}`);
}

/**
 * POST /api/enoki-sponsor
 *
 * Wraps a client-built `TransactionKind` as an Enoki-sponsored transaction:
 * Enoki server signs the gas leg using its funded sponsor account (per the
 * app's `allowedMoveCallTargets` dashboard rules). Returns `{ bytes, digest }`.
 *
 * The client then asks its wallet to sign `bytes` and calls `/api/enoki-execute`
 * with `{ digest, userSignature }` to finalize submission.
 *
 * Disabled on localnet — the local gas station (`/api/sponsor`) handles that.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  if (NETWORK === "localnet") {
    return NextResponse.json(
      {
        error:
          "/api/enoki-sponsor is disabled on localnet. Use /api/sponsor (local " +
          "gas station) for localnet flows.",
      },
      { status: 410 },
    );
  }

  let body: SponsorRequestBody;
  try {
    body = (await req.json()) as SponsorRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }
  if (!body.txKindBytes || !body.sender) {
    return NextResponse.json(
      { error: "txKindBytes and sender are required" },
      { status: 400 },
    );
  }

  try {
    const res = await enokiClient().createSponsoredTransaction({
      network: enokiNetwork(),
      sender: body.sender,
      transactionKindBytes: body.txKindBytes,
    });
    const response: SponsorResponseBody = { bytes: res.bytes, digest: res.digest };
    return NextResponse.json(response);
  } catch (err) {
    if (err instanceof EnokiClientError) {
      const first = err.errors[0];
      return NextResponse.json(
        {
          error: `enoki sponsor failed (${err.status} ${err.code}): ${first?.message ?? err.message}`,
        },
        { status: 500 },
      );
    }
    return NextResponse.json(
      { error: `enoki sponsor failed: ${err instanceof Error ? err.message : err}` },
      { status: 500 },
    );
  }
}
