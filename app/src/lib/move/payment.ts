import { Transaction, type TransactionArgument } from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";
import { buildAcAuth } from "./auth";

/** Sui's shared Clock object — passed to any tx that needs `&Clock`. */
const CLOCK_ID = "0x6";

/**
 * `merchant::create_invoice(self, &auth, variant_ids, quantities, order_ref, clock, ctx) -> ID`.
 * The returned PTB argument is the freshly-minted invoice id (the QR value).
 * The invoice itself is stored inside `Merchant.invoices`, not a shared object.
 */
export function buildCreateInvoice(
  tx: Transaction,
  args: {
    variantIds: string[];
    quantities: bigint[];
    orderRef: string;
  },
) {
  const auth = buildAcAuth(tx, "CashierRole");
  return tx.moveCall({
    target: `${deployment.packageId}::merchant::create_invoice`,
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

/**
 * `merchant::pay<C>(self, invoice_id, send_request, policy_s, customer_loy_acct, clock)`.
 * PAS-based settlement: the customer's `send_funds` request hands the stablecoin to
 * the merchant's payout PAS account. The send request must already be built +
 * approved (see `lib/move/pas.ts` and `lib/move/stablecoin.ts`).
 */
export function buildPay(
  tx: Transaction,
  args: {
    invoiceId: string;
    sendRequest: TransactionArgument;
    customerLoyaltyAccountId: string;
  },
): void {
  tx.moveCall({
    target: `${deployment.packageId}::merchant::pay`,
    typeArguments: [deployment.stablecoinType],
    arguments: [
      tx.object(deployment.merchantId),
      tx.pure.id(args.invoiceId),
      args.sendRequest,
      tx.object(deployment.stablecoinPolicyId),
      tx.object(args.customerLoyaltyAccountId),
      tx.object(CLOCK_ID),
    ],
  });
}

/**
 * `merchant::pay_with_coin<C>(self, invoice_id, coin, customer_loy_acct, clock)`.
 * Open-loop settlement: hand over a plain `Coin<C>` and the merchant routes it to
 * the payout address. Loyalty still credits `customer_loyalty_account`. The
 * receipt's `customer` is whoever owns the loyalty account, not a proven payer.
 */
export function buildPayWithCoin(
  tx: Transaction,
  args: {
    invoiceId: string;
    coin: TransactionArgument;
    customerLoyaltyAccountId: string;
  },
): void {
  tx.moveCall({
    target: `${deployment.packageId}::merchant::pay_with_coin`,
    typeArguments: [deployment.stablecoinType],
    arguments: [
      tx.object(deployment.merchantId),
      tx.pure.id(args.invoiceId),
      args.coin,
      tx.object(args.customerLoyaltyAccountId),
      tx.object(CLOCK_ID),
    ],
  });
}

/** `merchant::cancel_expired_invoice(self, invoice_id, clock)` — permissionless after expiry.
 *  Distinct from the `MerchantRole`-gated `merchant::cancel_invoice` used for early
 *  invalidation of a still-open invoice (not wired into the FE yet). */
export function buildCancelExpiredInvoice(tx: Transaction, invoiceId: string): void {
  tx.moveCall({
    target: `${deployment.packageId}::merchant::cancel_expired_invoice`,
    arguments: [
      tx.object(deployment.merchantId),
      tx.pure.id(invoiceId),
      tx.object(CLOCK_ID),
    ],
  });
}

/**
 * `merchant::prune_invoice_receipts(self, &auth, ids)` — MerchantRole-gated
 * storage cleanup. Receipts are redundant with `InvoicePaid` events so pruning
 * loses no canonical history.
 */
export function buildPruneInvoiceReceipts(tx: Transaction, ids: string[]): void {
  const auth = buildAcAuth(tx, "MerchantRole");
  tx.moveCall({
    target: `${deployment.packageId}::merchant::prune_invoice_receipts`,
    arguments: [tx.object(deployment.merchantId), auth, tx.pure.vector("id", ids)],
  });
}
