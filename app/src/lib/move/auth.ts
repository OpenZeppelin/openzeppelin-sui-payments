import { Transaction, type TransactionResult } from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";

/** Operational roles defined on the payments Merchant. */
export type RoleName = "MerchantRole" | "CatalogManagerRole" | "CashierRole";

/**
 * Builds `access_control::new_auth<MERCHANT, Role>(&ac, ctx)` and returns the
 * resulting `Auth<Role>` value as a PTB argument that can be passed into any
 * role-gated entry point.
 *
 * Note: when `openzeppelin_access` is bundled into our publish via
 * `--with-unpublished-dependencies`, it inherits the payments package's
 * address. So the call lives at `<paymentsPkg>::access_control::new_auth`,
 * not at a separate OZ-access package id.
 */
export function buildAcAuth(tx: Transaction, role: RoleName): TransactionResult {
  const pkg = deployment.packageId;
  return tx.moveCall({
    target: `${pkg}::access_control::new_auth`,
    typeArguments: [`${pkg}::merchant::MERCHANT`, `${pkg}::merchant::${role}`],
    arguments: [tx.object(deployment.accessControlId)],
  });
}
