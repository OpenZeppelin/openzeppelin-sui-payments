"use client";

import {
  useCurrentAccount,
  useSignAndExecuteTransaction,
  useSignTransaction,
  useSuiClient,
} from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { fromBase64, toBase64 } from "@mysten/sui/utils";
import { getZkLoginSignature } from "@mysten/sui/zklogin";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { getZkLoginSessionSnapshot } from "@/hooks/use-zklogin-session";
import { NETWORK } from "@/lib/sui-client";
import { ephemeralFromSecret } from "@/lib/zklogin/session";

interface SponsorOptions {
  /** Optional query keys to invalidate after a successful tx. */
  invalidate?: ReadonlyArray<ReadonlyArray<unknown>>;
  /** Optional gas budget (MIST). Honored only on the wallet-signs-and-executes
   *  path; the sponsor route sets its own gas budget on the wrapped tx. */
  gasBudget?: bigint;
  /** Optional success toast string; pass `null` to suppress. */
  successMessage?: string | null;
}

/**
 * useMutation wrapper that picks one of three tx submission paths, depending
 * on which identity is connected and which network we target:
 *
 *  A. **zkLogin session active** — build a `TransactionKind`, POST to
 *     `/api/sponsor` (localnet gas station), sign the returned bytes with the
 *     session's ephemeral key + Groth16 proof, submit `[zkSig, sponsorSig]`.
 *     No wallet UI at any point.
 *  B. **localnet, no zkLogin (Slush)** — same sponsor route, but the wallet's
 *     `useSignTransaction` co-signs instead of a zkLogin signature.
 *  C. **testnet/mainnet, wallet only** — plain `useSignAndExecuteTransaction`.
 *     When the connected wallet is Enoki-registered, Enoki auto-sponsors;
 *     otherwise the user's wallet pays gas.
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
      const zk = getZkLoginSessionSnapshot();
      const senderAddress = zk?.address ?? account?.address;
      if (!senderAddress) {
        throw new Error("Connect a wallet or log in with Google first");
      }

      const tx = new Transaction();
      build(tx, args);

      const useSponsor = zk !== null || NETWORK === "localnet";
      let digest: string;

      if (useSponsor) {
        tx.setSenderIfNotSet(senderAddress);
        const kindBytes = await tx.build({ client, onlyTransactionKind: true });

        const resp = await fetch("/api/sponsor", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            txKindBytes: toBase64(kindBytes),
            sender: senderAddress,
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

        let userSignature: string;
        if (zk) {
          // Sign the sponsor-returned bytes with the ephemeral key, then wrap
          // in a zkLoginSignature carrying the stored proof.
          const ephemeral = ephemeralFromSecret(zk.ephemeralPrivateKey);
          const { signature: ephemeralSig } = await ephemeral.signTransaction(
            fromBase64(bytes),
          );
          userSignature = getZkLoginSignature({
            inputs: { ...zk.proof, addressSeed: zk.addressSeed },
            maxEpoch: zk.maxEpoch,
            userSignature: ephemeralSig,
          });
        } else {
          // Slush (or any wallet-standard wallet) co-signs the same bytes.
          const { signature } = await signOnly({ transaction: bytes });
          userSignature = signature;
        }

        const submitted = await client.executeTransactionBlock({
          transactionBlock: bytes,
          signature: [userSignature, sponsorSignature],
        });
        digest = submitted.digest;
      } else {
        // Shared-chain wallet path: Enoki-registered wallet sponsors; other
        // wallets pay gas from their own SUI. Either way dapp-kit handles it.
        if (opts.gasBudget) tx.setGasBudget(opts.gasBudget);
        const result = await signAndExecute({ transaction: tx });
        digest = result.digest;
      }

      // Consistent chain-state view before we invalidate.
      await client.waitForTransaction({ digest });
      const full = await client.getTransactionBlock({
        digest,
        // `showEvents` is required by callers that pluck a created object's id
        // from an `InvoiceCreated`/`VoucherCreated` event.
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
