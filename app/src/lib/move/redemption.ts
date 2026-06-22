import { Transaction, type TransactionArgument } from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";
import { buildAcAuth } from "./auth";

const CLOCK_ID = "0x6";

/**
 * `merchant::create_voucher(self, unlock_req, policy_loyalty, variant_ids, quantities, clock, ctx) -> ID`.
 * Customer-side voucher creation. The returned PTB argument is the voucher id
 * (the QR value); the voucher itself is stored in `Merchant.vouchers`.
 */
export function buildCreateVoucher(
  tx: Transaction,
  args: {
    unlockRequest: TransactionArgument;
    variantIds: string[];
    quantities: bigint[];
  },
) {
  return tx.moveCall({
    target: `${deployment.packageId}::merchant::create_voucher`,
    arguments: [
      tx.object(deployment.merchantId),
      args.unlockRequest,
      tx.object(deployment.loyaltyPolicyId),
      tx.pure.vector("id", args.variantIds),
      tx.pure.vector("u64", args.quantities),
      tx.object(CLOCK_ID),
    ],
  });
}

/** `merchant::redeem(self, &auth, voucher_id, clock)`. */
export function buildRedeem(tx: Transaction, voucherId: string): void {
  const auth = buildAcAuth(tx, "CashierRole");
  tx.moveCall({
    target: `${deployment.packageId}::merchant::redeem`,
    arguments: [
      tx.object(deployment.merchantId),
      auth,
      tx.pure.id(voucherId),
      tx.object(CLOCK_ID),
    ],
  });
}

/**
 * `merchant::cancel_voucher(self, voucher_id, customer_loy_acct, clock)`. Permissionless
 * after expiry — returns the locked LOYALTY balance to the customer's PAS account.
 */
export function buildCancelVoucher(
  tx: Transaction,
  args: { voucherId: string; customerLoyaltyAccountId: string },
): void {
  tx.moveCall({
    target: `${deployment.packageId}::merchant::cancel_voucher`,
    arguments: [
      tx.object(deployment.merchantId),
      tx.pure.id(args.voucherId),
      tx.object(args.customerLoyaltyAccountId),
      tx.object(CLOCK_ID),
    ],
  });
}

/**
 * `merchant::prune_voucher_receipts(self, &auth, ids)` — MerchantRole-gated
 * storage cleanup, mirror of `prune_invoice_receipts`.
 */
export function buildPruneVoucherReceipts(tx: Transaction, ids: string[]): void {
  const auth = buildAcAuth(tx, "MerchantRole");
  tx.moveCall({
    target: `${deployment.packageId}::merchant::prune_voucher_receipts`,
    arguments: [tx.object(deployment.merchantId), auth, tx.pure.vector("id", ids)],
  });
}
