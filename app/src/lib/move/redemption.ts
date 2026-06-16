import {
  Transaction,
  type TransactionArgument,
  type TransactionResult,
} from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";
import { buildAcAuth } from "./auth";

const CLOCK_ID = "0x6";

/**
 * `redemption::new(merchant, unlock_req, policy_loyalty, variant_ids, quantities, clock, ctx) -> Voucher`.
 * Caller must then `redemption::share(voucher)`.
 */
export function buildRedemptionNew(
  tx: Transaction,
  args: {
    unlockRequest: TransactionArgument;
    variantIds: string[];
    quantities: bigint[];
  },
): TransactionResult {
  return tx.moveCall({
    target: `${deployment.packageId}::redemption::new`,
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

export function buildRedemptionShare(tx: Transaction, voucher: TransactionArgument): void {
  tx.moveCall({
    target: `${deployment.packageId}::redemption::share`,
    arguments: [voucher],
  });
}

export function buildRedemptionNewAndShare(
  tx: Transaction,
  args: {
    unlockRequest: TransactionArgument;
    variantIds: string[];
    quantities: bigint[];
  },
): void {
  const v = buildRedemptionNew(tx, args);
  buildRedemptionShare(tx, v);
}

/** `redemption::redeem(voucher, &auth, merchant, clock, ctx)`. */
export function buildRedemptionRedeem(tx: Transaction, voucherId: string): void {
  const auth = buildAcAuth(tx, "CashierRole");
  tx.moveCall({
    target: `${deployment.packageId}::redemption::redeem`,
    arguments: [
      tx.object(voucherId),
      auth,
      tx.object(deployment.merchantId),
      tx.object(CLOCK_ID),
    ],
  });
}

/** `redemption::cancel(voucher, customer_loy_acct, clock)` — permissionless after expiry. */
export function buildRedemptionCancel(
  tx: Transaction,
  args: { voucherId: string; customerLoyaltyAccountId: string },
): void {
  tx.moveCall({
    target: `${deployment.packageId}::redemption::cancel`,
    arguments: [
      tx.object(args.voucherId),
      tx.object(args.customerLoyaltyAccountId),
      tx.object(CLOCK_ID),
    ],
  });
}

/** `receipt::destroy<T>(receipt)` — customer-side cleanup. */
export function buildDestroyReceipt(
  tx: Transaction,
  args: { receiptId: string; receiptType: "Payment" | "Redemption" },
): void {
  const payloadType =
    args.receiptType === "Payment"
      ? `${deployment.packageId}::receipt::Payment`
      : `${deployment.packageId}::receipt::Redemption`;
  tx.moveCall({
    target: `${deployment.packageId}::receipt::destroy`,
    typeArguments: [payloadType],
    arguments: [tx.object(args.receiptId)],
  });
}
