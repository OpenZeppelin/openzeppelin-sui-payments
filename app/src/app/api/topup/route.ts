import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

import { deployerKeypair, deployerAddress } from "@/lib/deployer-server";
import { checkAndBumpAll, clientIp } from "@/lib/rate-limit";
import { NETWORK, networkConfig } from "@/lib/sui-client";

const PACKAGE_ID = process.env.NEXT_PUBLIC_PACKAGE_ID;
const STABLECOIN_PACKAGE_ID = process.env.NEXT_PUBLIC_STABLECOIN_PACKAGE_ID;
const STABLECOIN_TYPE = process.env.NEXT_PUBLIC_STABLECOIN_TYPE;

/**
 * Anti-abuse controls on the mock-USD faucet. The route is disabled on
 * mainnet at line ~50, but testnet stays open (deliberately unauthenticated
 * demo faucet). Without these two knobs an anonymous client could:
 *   1. Drain the deployer's testnet SUI (deployer pays gas for each mint).
 *   2. Mint unbounded mock-USD by repeating requests.
 *
 * Rate limit throttles request volume; the per-request cap bounds any
 * single mint. Same in-memory backing as `/api/enoki-sponsor` — swap for
 * shared storage on a public deployment (see `lib/rate-limit.ts`).
 */
const RATE_WINDOW_MS = Number(process.env.TOPUP_RATE_WINDOW_MS ?? 60_000);
const RATE_MAX_RECIPIENT = Number(process.env.TOPUP_RATE_MAX ?? 3);
const RATE_MAX_IP = Number(process.env.TOPUP_IP_RATE_MAX ?? 10);
/** Max mock-USD per request in base units (6 decimals). Default: 1,000,000. */
const MAX_AMOUNT_PER_REQUEST = BigInt(
  process.env.TOPUP_MAX_AMOUNT ?? "1000000000000",
);

type TopupRequestBody = {
  /** Recipient's PAS Account id (NOT the wallet address). */
  recipientAccountId: string;
  /** Amount in stablecoin base units (stringified bigint). */
  amount: string;
};

type TopupResponseBody = {
  digest: string;
  amount: string;
};

/**
 * POST /api/topup
 *
 * Deployer-signed faucet that mints `amount` mock-USD into the recipient's
 * PAS Account. Backed by `stablecoin_mock::faucet`, which requires the holder
 * of `TreasuryCap<STABLECOIN_MOCK>` — owned by the deployer after bootstrap.
 *
 * Dev / testnet only. Since this endpoint has no rate limit and no auth
 * beyond the deployer key sitting in `.env.local`, it's an unauthenticated
 * mint endpoint. That's fine for localnet + a mock-stablecoin testnet demo
 * (fake asset, deliberate faucet UX), but a real mainnet deployment must NOT
 * ship this route — the template pairs with a real stablecoin there and the
 * deployer wouldn't hold that TreasuryCap anyway, but the guard is
 * defense-in-depth.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  // Kill switch: refuse to serve on mainnet.
  if (NETWORK === "mainnet") {
    return NextResponse.json(
      {
        error:
          "/api/topup is a mock-stablecoin faucet and is disabled on mainnet. " +
          "Mainnet deployments pair with a real stablecoin; users acquire it via " +
          "that stablecoin's own on/off-ramps.",
      },
      { status: 410 },
    );
  }

  let body: TopupRequestBody;
  try {
    body = (await req.json()) as TopupRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  if (!body.recipientAccountId || !body.amount) {
    return NextResponse.json(
      { error: "recipientAccountId and amount are required" },
      { status: 400 },
    );
  }
  // Sui object ids are 32-byte hex (0x + 64 hex chars). Reject anything
  // else up front so a malformed id doesn't get inserted into the PTB and
  // fail cryptically deep in build.
  if (!/^0x[0-9a-fA-F]{64}$/.test(body.recipientAccountId)) {
    return NextResponse.json(
      { error: "recipientAccountId must be a 32-byte hex id (0x + 64 hex chars)" },
      { status: 400 },
    );
  }
  if (!STABLECOIN_PACKAGE_ID || !STABLECOIN_TYPE || !PACKAGE_ID) {
    return NextResponse.json(
      { error: "deployment env vars are missing — run `pnpm bootstrap`" },
      { status: 500 },
    );
  }

  let amount: bigint;
  try {
    amount = BigInt(body.amount);
  } catch {
    return NextResponse.json({ error: "amount must be a u64" }, { status: 400 });
  }
  if (amount <= 0n) {
    return NextResponse.json({ error: "amount must be > 0" }, { status: 400 });
  }
  // u64 upper bound — `tx.pure.u64(amount)` throws synchronously above this,
  // which would bypass the try/catch further down and surface as a raw 500.
  const U64_MAX = (1n << 64n) - 1n;
  if (amount > U64_MAX) {
    return NextResponse.json({ error: "amount exceeds u64 max" }, { status: 400 });
  }
  // Per-request ceiling — bounds any single mint even if rate-limiting is
  // ever bypassed. Base units: 1_000_000 = 1 USD (6 decimals).
  if (amount > MAX_AMOUNT_PER_REQUEST) {
    return NextResponse.json(
      { error: `amount exceeds per-request cap (${MAX_AMOUNT_PER_REQUEST.toString()} base units)` },
      { status: 400 },
    );
  }

  // Two independent buckets - per-recipient AND per-IP. Blocks the two
  // abuses this route enables: draining the deployer's testnet SUI by
  // spamming the faucet, and minting unbounded mock-USD to any recipient.
  const ip = clientIp(req);
  const rl = checkAndBumpAll([
    {
      key: `topup:recipient:${body.recipientAccountId}`,
      windowMs: RATE_WINDOW_MS,
      max: RATE_MAX_RECIPIENT,
    },
    { key: `topup:ip:${ip}`, windowMs: RATE_WINDOW_MS, max: RATE_MAX_IP },
  ]);
  if (!rl.ok) {
    const retryAfterSec = Math.max(1, Math.ceil((rl.retryAfterMs ?? RATE_WINDOW_MS) / 1000));
    return NextResponse.json(
      { error: `rate limit exceeded - retry in ${retryAfterSec}s` },
      { status: 429, headers: { "Retry-After": String(retryAfterSec) } },
    );
  }

  const keypair = deployerKeypair();
  const client = new SuiClient({ url: networkConfig[NETWORK].url });

  // Wrap the RPC-heavy critical section so a bad recipientAccountId or a
  // transient RPC hiccup returns the same `{ error }` envelope as the
  // sibling /api/sponsor and /api/enoki-* routes, instead of surfacing as a
  // raw framework 500.
  try {
    // Find the deployer-owned TreasuryCap<STABLECOIN_MOCK>. Iterate paginated owned
    // objects so we don't depend on it being on the first page.
    const wantType = `0x2::coin::TreasuryCap<${STABLECOIN_TYPE}>`;
    let treasuryCapId: string | null = null;
    let cursor: string | null = null;
    do {
      const page = await client.getOwnedObjects({
        owner: deployerAddress(),
        options: { showType: true },
        cursor: cursor ?? undefined,
      });
      const match = page.data.find((o) => o.data?.type === wantType);
      if (match?.data?.objectId) {
        treasuryCapId = match.data.objectId;
        break;
      }
      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
    if (!treasuryCapId) {
      return NextResponse.json(
        { error: `deployer ${deployerAddress()} does not own a ${wantType}` },
        { status: 500 },
      );
    }

    const tx = new Transaction();
    tx.moveCall({
      target: `${STABLECOIN_PACKAGE_ID}::stablecoin_mock::faucet`,
      arguments: [
        tx.object(treasuryCapId),
        tx.object(body.recipientAccountId),
        tx.pure.u64(amount),
      ],
    });
    tx.setGasBudget(100_000_000n);

    const result = await client.signAndExecuteTransaction({
      transaction: tx,
      signer: keypair,
      options: { showEffects: true },
    });
    if (result.effects?.status?.status !== "success") {
      return NextResponse.json(
        { error: `faucet tx failed: ${JSON.stringify(result.effects)}` },
        { status: 500 },
      );
    }
    await client.waitForTransaction({ digest: result.digest });

    const response: TopupResponseBody = { digest: result.digest, amount: amount.toString() };
    return NextResponse.json(response);
  } catch (err) {
    return NextResponse.json(
      { error: `topup failed: ${err instanceof Error ? err.message : String(err)}` },
      { status: 500 },
    );
  }
}
