import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

import { deployerKeypair } from "@/lib/deployer-server";
import { NETWORK, networkConfig } from "@/lib/sui-client";

const PACKAGE_ID = process.env.NEXT_PUBLIC_PACKAGE_ID;
const MERCHANT_ID = process.env.NEXT_PUBLIC_MERCHANT_ID;
const PAS_PACKAGE_ID = process.env.NEXT_PUBLIC_PAS_PACKAGE_ID;
const NAMESPACE_ID = process.env.NEXT_PUBLIC_NAMESPACE_ID;
const CLOCK_ID = "0x6";
const ID_DF_NAME_TYPE = "0x2::object::ID";

type CancelVoucherRequestBody = { voucherId: string };
type CancelVoucherResponseBody = { digest: string };

/**
 * POST /api/cancel-voucher
 *
 * `merchant::cancel_expired_voucher(self, voucher_id, customer_loyalty_account, clock)`
 * is permissionless after the voucher's `expires_at_ms`, but unlike
 * `cancel_expired_invoice` it needs an extra arg: the customer's PAS account to
 * deposit the unlocked LOY back into. We resolve that here:
 *
 *   1. Look up the voucher via the merchant's `vouchers: Table<ID, Voucher>`
 *      dynamic field to read its `customer` address.
 *   2. devInspect `namespace::account_address(ns, customer)` to derive the
 *      deterministic PAS account id for that customer.
 *   3. Build + sign the cancel PTB with the server-side `deployerKeypair`.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  let body: CancelVoucherRequestBody;
  try {
    body = (await req.json()) as CancelVoucherRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }
  if (!body.voucherId) {
    return NextResponse.json({ error: "voucherId is required" }, { status: 400 });
  }
  if (!PACKAGE_ID || !MERCHANT_ID || !PAS_PACKAGE_ID || !NAMESPACE_ID) {
    return NextResponse.json(
      { error: "deployment env vars are missing — run `pnpm bootstrap`" },
      { status: 500 },
    );
  }

  const keypair = deployerKeypair();
  const client = new SuiClient({ url: networkConfig[NETWORK].url });

  // 1. Read voucher from merchant.vouchers to find its customer address.
  const merchant = await client.getObject({
    id: MERCHANT_ID,
    options: { showContent: true },
  });
  const vouchersTableId = (
    (merchant.data?.content as { fields?: { vouchers?: { fields?: { id?: { id?: string } } } } } | null | undefined)
      ?.fields?.vouchers?.fields?.id?.id
  );
  if (!vouchersTableId) {
    return NextResponse.json(
      { error: "could not locate merchant.vouchers table" },
      { status: 500 },
    );
  }
  const voucherField = await client.getDynamicFieldObject({
    parentId: vouchersTableId,
    name: { type: ID_DF_NAME_TYPE, value: body.voucherId },
  });
  const customer = (
    (voucherField.data?.content as
      | { fields?: { value?: { fields?: { customer?: string } } } }
      | null
      | undefined)?.fields?.value?.fields?.customer
  );
  if (!customer) {
    return NextResponse.json(
      { error: `voucher ${body.voucherId} not found (already canceled or redeemed?)` },
      { status: 404 },
    );
  }

  // 2. Derive the customer's PAS account id via devInspect.
  const probe = new Transaction();
  probe.moveCall({
    target: `${PAS_PACKAGE_ID}::namespace::account_address`,
    arguments: [probe.object(NAMESPACE_ID), probe.pure.address(customer)],
  });
  const probeResult = await client.devInspectTransactionBlock({
    sender: customer,
    transactionBlock: probe,
  });
  const bytes = probeResult.results?.[0]?.returnValues?.[0]?.[0];
  if (!bytes) {
    return NextResponse.json(
      { error: "could not derive customer's PAS account address" },
      { status: 500 },
    );
  }
  const customerAccountId =
    "0x" +
    Array.from(bytes as number[])
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

  // 3. Build + execute the cancel PTB.
  const tx = new Transaction();
  tx.moveCall({
    target: `${PACKAGE_ID}::merchant::cancel_expired_voucher`,
    arguments: [
      tx.object(MERCHANT_ID),
      tx.pure.id(body.voucherId),
      tx.object(customerAccountId),
      tx.object(CLOCK_ID),
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
      { error: `cancel_expired_voucher failed: ${JSON.stringify(result.effects)}` },
      { status: 500 },
    );
  }
  await client.waitForTransaction({ digest: result.digest });

  const response: CancelVoucherResponseBody = { digest: result.digest };
  return NextResponse.json(response);
}
