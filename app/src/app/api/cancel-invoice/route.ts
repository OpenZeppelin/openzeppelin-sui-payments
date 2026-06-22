import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

import { sponsorKeypair } from "@/lib/sponsor-server";
import { NETWORK, networkConfig } from "@/lib/sui-client";

const PACKAGE_ID = process.env.NEXT_PUBLIC_PACKAGE_ID;
const MERCHANT_ID = process.env.NEXT_PUBLIC_MERCHANT_ID;
const CLOCK_ID = "0x6";

type CancelInvoiceRequestBody = {
  invoiceId: string;
};

type CancelInvoiceResponseBody = {
  digest: string;
};

/**
 * POST /api/cancel-invoice
 *
 * `merchant::cancel_invoice(self, invoice_id, clock)` is permissionless after
 * the invoice's `expires_at_ms`, so the sponsor can sign + pay on the
 * merchant's behalf. Storage rebate goes to the sponsor.
 *
 * Aborts here also surface a useful error: `ENotExpired` if the client UI
 * marked something expired prematurely (e.g. clock skew), or `EInvoiceNotFound`
 * if the invoice was canceled in a parallel tx.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  let body: CancelInvoiceRequestBody;
  try {
    body = (await req.json()) as CancelInvoiceRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }
  if (!body.invoiceId) {
    return NextResponse.json({ error: "invoiceId is required" }, { status: 400 });
  }
  if (!PACKAGE_ID || !MERCHANT_ID) {
    return NextResponse.json(
      { error: "deployment env vars are missing — run `pnpm bootstrap`" },
      { status: 500 },
    );
  }

  const keypair = sponsorKeypair();
  const client = new SuiClient({ url: networkConfig[NETWORK].url });

  const tx = new Transaction();
  tx.moveCall({
    target: `${PACKAGE_ID}::merchant::cancel_invoice`,
    arguments: [tx.object(MERCHANT_ID), tx.pure.id(body.invoiceId), tx.object(CLOCK_ID)],
  });
  tx.setGasBudget(50_000_000n);

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: { showEffects: true },
  });
  if (result.effects?.status?.status !== "success") {
    return NextResponse.json(
      { error: `cancel_invoice failed: ${JSON.stringify(result.effects)}` },
      { status: 500 },
    );
  }
  await client.waitForTransaction({ digest: result.digest });

  const response: CancelInvoiceResponseBody = { digest: result.digest };
  return NextResponse.json(response);
}
