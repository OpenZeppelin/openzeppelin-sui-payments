"use client";

import { useSuiClient } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useQuery } from "@tanstack/react-query";

import { deployment } from "@/lib/deployment";

/**
 * Does `address` hold any of the three operational roles gated on this
 * merchant's `AccessControl<MERCHANT>` — `MerchantRole`, `CatalogManagerRole`,
 * `CashierRole`? Dev-inspects `openzeppelin_access::access_control::has_role`
 * three times in a single PTB (chain-agnostic, no gas), OR's the results.
 *
 * Used by the landing page to route freshly-connected users straight to the
 * merchant view when they hold any staff role, and to the customer view
 * otherwise.
 */
const ROLES = ["MerchantRole", "CatalogManagerRole", "CashierRole"] as const;

export function useHasMerchantRole(address: string | null) {
  const client = useSuiClient();
  return useQuery({
    queryKey: ["has-merchant-role", address ?? ""],
    enabled: Boolean(address),
    queryFn: async () => {
      const tx = new Transaction();
      const merchantOtw = `${deployment.packageId}::merchant::MERCHANT`;
      for (const role of ROLES) {
        tx.moveCall({
          target: `${deployment.ozAccessPackageId}::access_control::has_role`,
          typeArguments: [merchantOtw, `${deployment.packageId}::merchant::${role}`],
          arguments: [tx.object(deployment.accessControlId), tx.pure.address(address!)],
        });
      }
      const result = await client.devInspectTransactionBlock({
        sender: address!,
        transactionBlock: tx,
      });
      // Each moveCall's first return is a bool serialized as a single byte
      // (0 = false, 1 = true). If any of the three came back true, the
      // address holds some merchant-side role.
      const bools = (result.results ?? []).map(
        (r) => r.returnValues?.[0]?.[0]?.[0] === 1,
      );
      return bools.some(Boolean);
    },
  });
}
