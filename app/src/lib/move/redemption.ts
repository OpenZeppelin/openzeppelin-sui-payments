import { Transaction, type TransactionArgument } from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";
import { buildAcAuth } from "./auth";

const CLOCK_ID = "0x6";

/**
 * `merchant::create_voucher(self, unlock_req, policy_loyalty, variant_ids,
 * quantities, redeem_hash, clock, ctx) -> ID`.
 *
 * Customer-side voucher creation. `redeemHash` is the 32-byte blake2b256
 * commitment to a customer-chosen secret preimage (see `lib/preimage`); the
 * customer keeps the preimage in localStorage and reveals it at the till via
 * the QR. The contract requires the matching preimage in `merchant::redeem`,
 * so `CashierRole` alone cannot sweep vouchers.
 *
 * The returned PTB argument is the voucher id (used as the QR's `v` field);
 * the voucher itself is stored in `Merchant.vouchers`.
 */
export function buildCreateVoucher(
  tx: Transaction,
  args: {
    unlockRequest: TransactionArgument;
    variantIds: string[];
    quantities: bigint[];
    redeemHash: Uint8Array;
  },
) {
  if (args.redeemHash.length !== 32) {
    throw new Error(
      `redeemHash must be 32 bytes (blake2b256 digest); got ${args.redeemHash.length}`,
    );
  }
  return tx.moveCall({
    target: `${deployment.packageId}::merchant::create_voucher`,
    arguments: [
      tx.object(deployment.merchantId),
      args.unlockRequest,
      tx.object(deployment.loyaltyPolicyId),
      tx.pure.vector("id", args.variantIds),
      tx.pure.vector("u64", args.quantities),
      tx.pure.vector("u8", Array.from(args.redeemHash)),
      tx.object(CLOCK_ID),
    ],
  });
}

/**
 * `merchant::redeem(self, &auth, voucher_id, preimage, clock)`.
 *
 * `preimage` is the 32-byte secret the customer revealed via the scanned QR.
 * The contract asserts `blake2b256(preimage) == voucher.redeem_hash` before
 * burning the locked LOYALTY.
 */
export function buildRedeem(tx: Transaction, voucherId: string, preimage: Uint8Array): void {
  const auth = buildAcAuth(tx, "CashierRole");
  tx.moveCall({
    target: `${deployment.packageId}::merchant::redeem`,
    arguments: [
      tx.object(deployment.merchantId),
      auth,
      tx.pure.id(voucherId),
      tx.pure.vector("u8", Array.from(preimage)),
      tx.object(CLOCK_ID),
    ],
  });
}

/**
 * `merchant::cancel_expired_voucher(self, voucher_id, customer_loy_acct, clock)`. Permissionless
 * after expiry — returns the locked LOYALTY balance to the customer's PAS account.
 */
export function buildCancelVoucher(
  tx: Transaction,
  args: { voucherId: string; customerLoyaltyAccountId: string },
): void {
  tx.moveCall({
    target: `${deployment.packageId}::merchant::cancel_expired_voucher`,
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
