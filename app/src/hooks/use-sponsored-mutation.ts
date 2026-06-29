"use client";

import {
  useCurrentAccount,
  useSignAndExecuteTransaction,
  useSignTransaction,
  useSuiClient,
} from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { toBase64 } from "@mysten/sui/utils";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { NETWORK } from "@/lib/sui-client";

interface SponsorOptions {
  /** Optional query keys to invalidate after a successful tx. */
  invalidate?: ReadonlyArray<ReadonlyArray<unknown>>;
  /** Optional gas budget (MIST). Honored only on the non-sponsored path; the
   *  sponsor route sets its own gas budget on the wrapped tx. */
  gasBudget?: bigint;
  /** Optional success toast string; pass `null` to suppress. */
  successMessage?: string | null;
}

/**
 * useMutation wrapper that:
 *   1. Lets callers build a `Transaction` synchronously (via the `build` arg).
 *   2. Routes the tx through one of two paths depending on NETWORK:
 *      - **localnet**: build a `TransactionKind`, POST to `/api/sponsor` for
 *        a sponsor-signed gas leg, ask the wallet to co-sign the same bytes
 *        via `useSignTransaction`, submit `[userSig, sponsorSig]` directly.
 *      - **testnet/mainnet**: `useSignAndExecuteTransaction` — when the wallet
 *        is an Enoki zkLogin wallet, Enoki sponsors automatically; otherwise
 *        the user's wallet pays gas.
 *   3. Toasts success/failure (sonner) + invalidates query keys.
 */
export function useSponsoredMutation<TArgs>(
  build: (tx: Transaction, args: TArgs) => void,
  opts: SponsorOptions = {},
) {
  const account = useCurrentAccount();
  const client = useSuiClient();
  const queryClient = useQueryClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { mutateAsync: signOnly } = useSignTransaction();

  return useMutation({
    mutationFn: async (args: TArgs) => {
      if (!account) throw new Error("Connect a wallet first");

      const tx = new Transaction();
      build(tx, args);

      let digest: string;
      if (NETWORK === "localnet") {
        // Build the TransactionKind (no sender/gas/expiration) and hand it off
        // to the local gas station for sponsorship.
        tx.setSenderIfNotSet(account.address);
        const kindBytes = await tx.build({ client, onlyTransactionKind: true });

        const resp = await fetch("/api/sponsor", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            txKindBytes: toBase64(kindBytes),
            sender: account.address,
          }),
        });
        if (!resp.ok) {
          const err = (await resp.json().catch(() => null)) as { error?: string } | null;
          throw new Error(err?.error ?? `sponsor failed (${resp.status})`);
        }
        const { bytes, sponsorSignature } = (await resp.json()) as {
          bytes: string;
          sponsorSignature: string;
        };

        // Wallet co-signs the exact bytes the sponsor signed. dapp-kit's
        // `useSignTransaction` accepts a base64 string for already-built tx
        // bytes; `executeTransactionBlock` takes the same.
        const { signature: userSignature } = await signOnly({ transaction: bytes });

        const submitted = await client.executeTransactionBlock({
          transactionBlock: bytes,
          signature: [userSignature, sponsorSignature],
        });
        digest = submitted.digest;
      } else {
        // Shared-chain path: Enoki wallet sponsors automatically; non-Enoki
        // wallets pay their own gas. Either way the dapp-kit hook covers it.
        if (opts.gasBudget) tx.setGasBudget(opts.gasBudget);
        const result = await signAndExecute({ transaction: tx });
        digest = result.digest;
      }

      // Make sure the wallet returns to a consistent view of chain state.
      await client.waitForTransaction({ digest });
      // Resolve effects + status (both code paths above return only the digest).
      const full = await client.getTransactionBlock({
        digest,
        // `showEvents` is required by callers that pluck a created object's id
        // from the emitted `InvoiceCreated`/`VoucherCreated` event (rather than
        // re-querying the table).
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
