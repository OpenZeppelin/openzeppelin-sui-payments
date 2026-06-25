import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

import { deployerKeypair } from "@/lib/deployer-server";
import { NETWORK, networkConfig } from "@/lib/sui-client";

const PAS_PACKAGE_ID = process.env.NEXT_PUBLIC_PAS_PACKAGE_ID;
const NAMESPACE_ID = process.env.NEXT_PUBLIC_NAMESPACE_ID;

type InitAccountRequestBody = {
  /** Owner address (the customer's wallet) that will own the new PAS Account. */
  ownerAddress: string;
};

type InitAccountResponseBody = {
  digest: string;
};

/**
 * POST /api/init-account
 *
 * `pas::account::create_and_share(namespace, owner_address)` doesn't require an
 * `&Auth` from the owner — it just takes their address as a value parameter,
 * so anyone can create an account for anyone. The server-side `deployerKeypair`
 * (funded by `pnpm bootstrap` on localnet) pays gas, so the customer never has
 * to open their wallet for this one-time setup.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  let body: InitAccountRequestBody;
  try {
    body = (await req.json()) as InitAccountRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }
  if (!body.ownerAddress) {
    return NextResponse.json({ error: "ownerAddress is required" }, { status: 400 });
  }
  if (!PAS_PACKAGE_ID || !NAMESPACE_ID) {
    return NextResponse.json(
      { error: "deployment env vars are missing — run `pnpm bootstrap`" },
      { status: 500 },
    );
  }

  const keypair = deployerKeypair();
  const client = new SuiClient({ url: networkConfig[NETWORK].url });

  const tx = new Transaction();
  tx.moveCall({
    target: `${PAS_PACKAGE_ID}::account::create_and_share`,
    arguments: [tx.object(NAMESPACE_ID), tx.pure.address(body.ownerAddress)],
  });
  tx.setGasBudget(50_000_000n);

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: { showEffects: true },
  });
  if (result.effects?.status?.status !== "success") {
    return NextResponse.json(
      { error: `create_and_share failed: ${JSON.stringify(result.effects)}` },
      { status: 500 },
    );
  }
  await client.waitForTransaction({ digest: result.digest });

  const response: InitAccountResponseBody = { digest: result.digest };
  return NextResponse.json(response);
}
