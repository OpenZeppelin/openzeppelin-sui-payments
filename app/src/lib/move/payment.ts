import {
  Transaction,
  type TransactionArgument,
  type TransactionResult,
} from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";
import { buildAcAuth } from "./auth";

/** Sui's shared Clock object — passed to any tx that needs `&Clock`. */
const CLOCK_ID = "0x6";

/**
 * `payment::new(merchant, &auth, variant_ids, quantities, order_ref, clock, ctx) -> Invoice`.
 * Returned `Invoice` is by-value with no `drop`/`store` — caller must follow
 * up with `payment::share(invoice)` (see {@link buildPaymentShare}).
 */
export function buildPaymentNew(
  tx: Transaction,
  args: {
    variantIds: string[];
    quantities: bigint[];
    orderRef: string;
  },
): TransactionResult {
  const auth = buildAcAuth(tx, "CashierRole");
  return tx.moveCall({
    target: `${deployment.packageId}::payment::new`,
    arguments: [
      tx.object(deployment.merchantId),
      auth,
      tx.pure.vector("id", args.variantIds),
      tx.pure.vector("u64", args.quantities),
      tx.pure.vector("u8", Array.from(new TextEncoder().encode(args.orderRef))),
      tx.object(CLOCK_ID),
    ],
  });
}

/** `payment::share(invoice)` — shares the freshly-built `Invoice`. */
export function buildPaymentShare(tx: Transaction, invoice: TransactionArgument): void {
  tx.moveCall({
    target: `${deployment.packageId}::payment::share`,
    arguments: [invoice],
  });
}

/** Convenience: `new` + `share` chained. */
export function buildPaymentNewAndShare(
  tx: Transaction,
  args: { variantIds: string[]; quantities: bigint[]; orderRef: string },
): void {
  const invoice = buildPaymentNew(tx, args);
  buildPaymentShare(tx, invoice);
}

/**
 * `payment::pay<S>(invoice, merchant, send_req, policy_s, customer_loy_acct, clock, ctx)`.
 * The send_request must already be built + approved by the customer (see
 * `lib/move/pas.ts` and `lib/move/stablecoin.ts`).
 */
export function buildPaymentPay(
  tx: Transaction,
  args: {
    invoiceId: string;
    sendRequest: TransactionArgument;
    customerLoyaltyAccountId: string;
  },
): void {
  tx.moveCall({
    target: `${deployment.packageId}::payment::pay`,
    typeArguments: [deployment.stablecoinType],
    arguments: [
      tx.object(args.invoiceId),
      tx.object(deployment.merchantId),
      args.sendRequest,
      tx.object(deployment.stablecoinPolicyId),
      tx.object(args.customerLoyaltyAccountId),
      tx.object(CLOCK_ID),
    ],
  });
}

/** `payment::cancel(invoice, clock)` — permissionless after expiry. */
export function buildPaymentCancel(tx: Transaction, invoiceId: string): void {
  tx.moveCall({
    target: `${deployment.packageId}::payment::cancel`,
    arguments: [tx.object(invoiceId), tx.object(CLOCK_ID)],
  });
}
