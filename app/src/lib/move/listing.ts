import { Transaction, type TransactionResult } from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";

/**
 * `listing::new(name, ctx) -> Listing`. The result is a *value*, not an object —
 * the caller must chain it into something that stores it (e.g. `merchant::add_listing`)
 * or the PTB will fail because `Listing` has no `key`/`drop`.
 */
export function buildNewListing(tx: Transaction, name: string): TransactionResult {
  return tx.moveCall({
    target: `${deployment.packageId}::listing::new`,
    arguments: [tx.pure.string(name)],
  });
}

/**
 * `listing::new_variant(name, price, loyalty_price, ctx) -> Variant`. Same
 * value-returning shape — chain into `merchant::add_listing_variant` or into
 * a `Listing` accumulator.
 */
export function buildNewVariant(
  tx: Transaction,
  args: {
    name: string;
    price: bigint;
    loyaltyPrice: bigint | null;
  },
): TransactionResult {
  return tx.moveCall({
    target: `${deployment.packageId}::listing::new_variant`,
    arguments: [
      tx.pure.string(args.name),
      tx.pure.u64(args.price),
      tx.pure.option("u64", args.loyaltyPrice ?? null),
    ],
  });
}
