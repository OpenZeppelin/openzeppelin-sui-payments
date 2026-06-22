"use client";

import { useCurrentAccount, useSignTransaction, useSuiClient } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { sponsorAndExecute } from "@/lib/sponsored-tx";

interface SponsorOptions {
  /** Optional query keys to invalidate after a successful tx. */
  invalidate?: ReadonlyArray<ReadonlyArray<unknown>>;
  /** Optional gas budget (MIST). Defaults to the server's value. */
  gasBudget?: bigint;
  /** Optional success toast string; pass `null` to suppress. */
  successMessage?: string | null;
}

/**
 * useMutation wrapper that:
 *   1. Lets callers build a `Transaction` synchronously (via the `build` arg).
 *   2. Orchestrates the sponsored-tx dance (server signs gas, wallet signs
 *      sender, both submit).
 *   3. Toasts success/failure (sonner) + invalidates query keys.
 *
 * Pages call this to fire any role-gated or customer-side write tx without
 * touching the sponsorship plumbing directly.
 */
export function useSponsoredMutation<TArgs>(
  build: (tx: Transaction, args: TArgs) => void,
  opts: SponsorOptions = {},
) {
  const account = useCurrentAccount();
  const client = useSuiClient();
  const queryClient = useQueryClient();
  const { mutateAsync: signTransaction } = useSignTransaction();

  return useMutation({
    mutationFn: async (args: TArgs) => {
      if (!account) throw new Error("Connect a wallet first");

      const tx = new Transaction();
      build(tx, args);

      const result = await sponsorAndExecute({
        transaction: tx,
        sender: account.address,
        signTransaction,
        client,
        gasBudget: opts.gasBudget,
      });
      // Make sure the wallet returns to a consistent view of chain state.
      await client.waitForTransaction({ digest: result.digest });
      return result;
    },
    onSuccess: async () => {
      if (opts.successMessage !== null) {
        toast.success(opts.successMessage ?? "Transaction confirmed");
      }
      for (const key of opts.invalidate ?? []) {
        await queryClient.invalidateQueries({ queryKey: key });
      }
    },
    onError: (err) => {
      toast.error(
        err instanceof Error ? err.message : "Transaction failed (unknown error)",
      );
    },
  });
}
