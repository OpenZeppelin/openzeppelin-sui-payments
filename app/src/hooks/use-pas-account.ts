"use client";

import { useSuiClient } from "@mysten/dapp-kit";
import { useQuery } from "@tanstack/react-query";

import { fetchAccountAddress } from "@/hooks/queries";

/**
 * Returns the (deterministic) PAS Account id for a given Sui owner address.
 * Returns `null` if the chain reports no account (which usually just means
 * `account::create_and_share` hasn't been called for that owner yet).
 *
 * Internally uses `devInspectTransactionBlock` against `account::account_address`
 * so it doesn't burn gas / signer.
 */
export function usePasAccount(ownerAddress: string | null | undefined) {
  const client = useSuiClient();
  return useQuery({
    queryKey: ["pas-account", ownerAddress ?? ""],
    enabled: Boolean(ownerAddress),
    queryFn: async () => {
      const id = await fetchAccountAddress(client, ownerAddress!);
      if (!id) return null;
      // Confirm the account object actually exists (the deterministic address
      // may not yet be initialised on-chain).
      const o = await client.getObject({ id, options: { showType: true } });
      return o.data?.objectId ? id : null;
    },
  });
}
