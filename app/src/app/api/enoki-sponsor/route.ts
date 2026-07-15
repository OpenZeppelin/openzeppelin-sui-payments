import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { EnokiClientError } from "@mysten/enoki";

import { enokiClient } from "@/lib/enoki-server";
import { checkAndBumpAll, clientIp, parsePositiveInt } from "@/lib/rate-limit";
import { NETWORK } from "@/lib/sui-client";

/**
 * Two independent buckets — per-sender AND per-IP — checked atomically.
 * An attacker rotating IPs still trips the sender bucket; an attacker
 * faking senders still trips the shared IP bucket. Tunable via env; see
 * `.env.example`. Same in-memory backing caveat as elsewhere — swap for
 * shared storage on a public deployment.
 */
const RATE_WINDOW_MS = parsePositiveInt(
  "ENOKI_SPONSOR_RATE_WINDOW_MS",
  process.env.ENOKI_SPONSOR_RATE_WINDOW_MS,
  60_000,
);
const RATE_MAX_SENDER = parsePositiveInt(
  "ENOKI_SPONSOR_RATE_MAX",
  process.env.ENOKI_SPONSOR_RATE_MAX,
  10,
);
const RATE_MAX_IP = parsePositiveInt(
  "ENOKI_SPONSOR_IP_RATE_MAX",
  process.env.ENOKI_SPONSOR_IP_RATE_MAX,
  30,
);

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

  // Independent per-sender + per-IP buckets, checked atomically. Rotating
  // one dimension still trips the other's cap. Sender is lowercased for the
  // bucket key so mixed-case hex variants (`0xABC…` vs `0xabc…`) share the
  // same throttle - request processing below keeps the original casing.
  const ip = clientIp(req);
  const senderKey = body.sender.toLowerCase();
  const rl = checkAndBumpAll([
    { key: `enoki-sponsor:sender:${senderKey}`, windowMs: RATE_WINDOW_MS, max: RATE_MAX_SENDER },
    { key: `enoki-sponsor:ip:${ip}`, windowMs: RATE_WINDOW_MS, max: RATE_MAX_IP },
  ]);
  if (!rl.ok) {
    const retryAfterSec = Math.max(1, Math.ceil((rl.retryAfterMs ?? RATE_WINDOW_MS) / 1000));
    return NextResponse.json(
      { error: `rate limit exceeded - retry in ${retryAfterSec}s` },
      { status: 429, headers: { "Retry-After": String(retryAfterSec) } },
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
      // Forward Enoki's status when it's a 4xx (bad kind bytes, disallowed
      // move target, budget exhausted, etc.). Otherwise fall back to 500
      // so opaque upstream failures still bubble as server errors here.
      const status = err.status >= 400 && err.status < 500 ? err.status : 500;
      return NextResponse.json(
        {
          error: `enoki sponsor failed (${err.status} ${err.code}): ${first?.message ?? err.message}`,
        },
        { status },
      );
    }
    return NextResponse.json(
      { error: `enoki sponsor failed: ${err instanceof Error ? err.message : err}` },
      { status: 500 },
    );
  }
}
