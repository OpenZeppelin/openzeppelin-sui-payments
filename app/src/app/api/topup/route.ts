import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

import { deployerKeypair, deployerAddress } from "@/lib/deployer-server";
import { NETWORK, networkConfig } from "@/lib/sui-client";

const PACKAGE_ID = process.env.NEXT_PUBLIC_PACKAGE_ID;
const STABLECOIN_PACKAGE_ID = process.env.NEXT_PUBLIC_STABLECOIN_PACKAGE_ID;
const STABLECOIN_TYPE = process.env.NEXT_PUBLIC_STABLECOIN_TYPE;

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

  const keypair = deployerKeypair();
  const client = new SuiClient({ url: networkConfig[NETWORK].url });

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
}
