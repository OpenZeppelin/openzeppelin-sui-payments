import { Transaction, type TransactionArgument, type TransactionResult } from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";
import { buildAcAuth } from "./auth";

/** Wraps `merchant::add_listing(self, &auth, listing)`. Returns the listing ID. */
export function buildAddListing(
  tx: Transaction,
  listing: TransactionArgument,
): TransactionResult {
  const auth = buildAcAuth(tx, "CatalogManagerRole");
  return tx.moveCall({
    target: `${deployment.packageId}::merchant::add_listing`,
    arguments: [tx.object(deployment.merchantId), auth, listing],
  });
}

/** Wraps `merchant::remove_listing(self, &auth, id)`. */
export function buildRemoveListing(tx: Transaction, listingId: string): void {
  const auth = buildAcAuth(tx, "CatalogManagerRole");
  tx.moveCall({
    target: `${deployment.packageId}::merchant::remove_listing`,
    arguments: [tx.object(deployment.merchantId), auth, tx.pure.id(listingId)],
  });
}

/** Wraps `merchant::set_listing_status(self, &auth, listing_id, active)`. */
export function buildSetListingStatus(
  tx: Transaction,
  args: { listingId: string; active: boolean },
): void {
  const auth = buildAcAuth(tx, "CatalogManagerRole");
  tx.moveCall({
    target: `${deployment.packageId}::merchant::set_listing_status`,
    arguments: [
      tx.object(deployment.merchantId),
      auth,
      tx.pure.id(args.listingId),
      tx.pure.bool(args.active),
    ],
  });
}

/**
 * Wraps `merchant::add_listing_variant(self, &auth, listing_id, variant)`.
 * `listingId` accepts a string (when the id is known statically) or a
 * `TransactionArgument` from a previous PTB call (e.g. chaining from `add_listing`).
 */
export function buildAddListingVariant(
  tx: Transaction,
  args: { listingId: string | TransactionArgument; variant: TransactionArgument },
): TransactionResult {
  const auth = buildAcAuth(tx, "CatalogManagerRole");
  const listingIdArg =
    typeof args.listingId === "string" ? tx.pure.id(args.listingId) : args.listingId;
  return tx.moveCall({
    target: `${deployment.packageId}::merchant::add_listing_variant`,
    arguments: [tx.object(deployment.merchantId), auth, listingIdArg, args.variant],
  });
}

/** Wraps `merchant::remove_listing_variant(self, &auth, variant_id)`. */
export function buildRemoveListingVariant(tx: Transaction, variantId: string): void {
  const auth = buildAcAuth(tx, "CatalogManagerRole");
  tx.moveCall({
    target: `${deployment.packageId}::merchant::remove_listing_variant`,
    arguments: [tx.object(deployment.merchantId), auth, tx.pure.id(variantId)],
  });
}

// --- MerchantRole-gated identity / treasury ops ---

export function buildUpdateDisplay(
  tx: Transaction,
  args: { name: string; logoUrl: string | null },
): void {
  const auth = buildAcAuth(tx, "MerchantRole");
  tx.moveCall({
    target: `${deployment.packageId}::merchant::update_display`,
    arguments: [
      tx.object(deployment.merchantId),
      auth,
      tx.pure.string(args.name),
      tx.pure.option("string", args.logoUrl ?? null),
    ],
  });
}

/**
 * Builds `config::new<C>(&Currency<C>, payout_address, coefficient, max, invoice_ttl, voucher_ttl)`
 * then `merchant::update_config(self, &auth, cfg)`. The currency's decimals are
 * snapshotted into the resulting Config on-chain, so all four "what coin do we
 * accept" pieces — type tag, decimals, payout, and rate — flow through a single
 * atomic `update_config` call.
 */
export function buildUpdateConfig(
  tx: Transaction,
  args: {
    payoutAddress: string;
    loyaltyCoefficient: bigint;
    maxLoyaltyPerPayment: bigint;
    invoiceTtlMs: bigint;
    voucherTtlMs: bigint;
  },
): void {
  const auth = buildAcAuth(tx, "MerchantRole");
  const cfg = tx.moveCall({
    target: `${deployment.packageId}::config::new`,
    typeArguments: [deployment.stablecoinType],
    arguments: [
      tx.object(deployment.stablecoinCurrencyId),
      tx.pure.address(args.payoutAddress),
      tx.pure.u64(args.loyaltyCoefficient),
      tx.pure.u64(args.maxLoyaltyPerPayment),
      tx.pure.u64(args.invoiceTtlMs),
      tx.pure.u64(args.voucherTtlMs),
    ],
  });
  tx.moveCall({
    target: `${deployment.packageId}::merchant::update_config`,
    arguments: [tx.object(deployment.merchantId), auth, cfg],
  });
}
