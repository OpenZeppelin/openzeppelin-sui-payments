import { Transaction, type TransactionResult } from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";

/** Operational roles defined on the payments Merchant. */
export type RoleName = "MerchantRole" | "CatalogManagerRole" | "CashierRole";

/**
 * Builds `access_control::new_auth<MERCHANT, Role>(&ac, ctx)` and returns the
 * resulting `Auth<Role>` value as a PTB argument that can be passed into any
 * role-gated entry point.
 *
 * `new_auth` lives in the openzeppelin_access package; the MERCHANT OTW and
 * the `Role` phantom marker types live in our payments package.
 */
export function buildAcAuth(tx: Transaction, role: RoleName): TransactionResult {
  const payments = deployment.packageId;
  return tx.moveCall({
    target: `${deployment.ozAccessPackageId}::access_control::new_auth`,
    typeArguments: [
      `${payments}::merchant::MERCHANT`,
      `${payments}::merchant::${role}`,
    ],
    arguments: [tx.object(deployment.accessControlId)],
  });
}
