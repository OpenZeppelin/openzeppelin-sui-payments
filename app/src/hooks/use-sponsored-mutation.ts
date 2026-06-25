"use client";

import { useCurrentAccount, useSignAndExecuteTransaction, useSuiClient } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

interface SponsorOptions {
  /** Optional query keys to invalidate after a successful tx. */
  invalidate?: ReadonlyArray<ReadonlyArray<unknown>>;
  /** Optional gas budget (MIST). When omitted, the wallet picks one. */
  gasBudget?: bigint;
  /** Optional success toast string; pass `null` to suppress. */
  successMessage?: string | null;
}

/**
 * useMutation wrapper that:
 *   1. Lets callers build a `Transaction` synchronously (via the `build` arg).
 *   2. Asks the connected wallet (Slush etc.) to sign + execute — the user
 *      pays gas from their own SUI balance.
 *   3. Toasts success/failure (sonner) + invalidates query keys.
 *
 * Name kept for ABI parity with callers; despite the "Sponsored" name there
 * is currently no sponsor in the loop. A zkLogin path (no SUI on-hand) will
 * reintroduce a sponsor-only branch later — gate that on session type, not by
 * sponsoring every Slush-wallet tx.
 */
export function useSponsoredMutation<TArgs>(
  build: (tx: Transaction, args: TArgs) => void,
  opts: SponsorOptions = {},
) {
  const account = useCurrentAccount();
  const client = useSuiClient();
  const queryClient = useQueryClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();

  return useMutation({
    mutationFn: async (args: TArgs) => {
      if (!account) throw new Error("Connect a wallet first");

      const tx = new Transaction();
      build(tx, args);
      if (opts.gasBudget) tx.setGasBudget(opts.gasBudget);

      const result = await signAndExecute({ transaction: tx });
      // Make sure the wallet returns to a consistent view of chain state.
      await client.waitForTransaction({ digest: result.digest });
      // Resolve effects + status (`useSignAndExecuteTransaction` returns the
      // raw response which doesn't include effects by default).
      const full = await client.getTransactionBlock({
        digest: result.digest,
        // `showEvents` is required by callers that pluck a created object's id
        // from the emitted `InvoiceCreated`/`VoucherCreated` event (rather than
        // re-querying the table). `useSignAndExecuteTransaction` returns only
        // `{digest, rawTransaction}` so we fetch the full record here.
        options: { showEffects: true, showEvents: true },
      });
      if (full.effects?.status?.status !== "success") {
        const moveErr = full.effects?.status?.error ?? "unknown abort";
        throw new Error(`Transaction aborted on chain: ${moveErr}`);
      }
      return full;
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
