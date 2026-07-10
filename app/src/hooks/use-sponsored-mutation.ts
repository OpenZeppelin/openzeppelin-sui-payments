"use client";

import {
  useCurrentAccount,
  useCurrentWallet,
  useDisconnectWallet,
  useSignAndExecuteTransaction,
  useSignTransaction,
  useSuiClient,
} from "@mysten/dapp-kit";
import { isEnokiWallet } from "@mysten/enoki";
import { Transaction } from "@mysten/sui/transactions";
import { toBase64 } from "@mysten/sui/utils";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { NETWORK } from "@/lib/sui-client";

/**
 * Substring patterns Enoki's wallet throws when its internal zkLogin state
 * has gone away (expired proof, cleared sessionStorage after tab close,
 * ephemeral-key mismatch). All of them mean "session is toast — user must
 * sign in again." We convert these into a friendly disconnect + toast rather
 * than surface the raw internal-state error to the user.
 */
const ENOKI_SESSION_GONE_PATTERNS = [
  "Missing required parameters for proof generation",
  "Stored proof is expired",
  "Native signer not found in store",
  "does not match the currently connected Enoki address",
];

function isEnokiSessionGone(err: unknown): boolean {
  if (!(err instanceof Error)) return false;
  return ENOKI_SESSION_GONE_PATTERNS.some((p) => err.message.includes(p));
}

interface SponsorOptions {
  /** Optional query keys to invalidate after a successful tx. */
  invalidate?: ReadonlyArray<ReadonlyArray<unknown>>;
  /** Optional gas budget (MIST). Honored only on the wallet-signs-and-executes
   *  path; sponsor paths set their own gas budget on the wrapped tx. */
  gasBudget?: bigint;
  /** Optional success toast string; pass `null` to suppress. */
  successMessage?: string | null;
}

/**
 * Deployer address (public). Injected at build time by Next.js from
 * `NEXT_PUBLIC_DEPLOYER_ADDRESS`. Localnet-only failure mode: the deployer
 * doubles as the localnet gas sponsor, so a deployer-signed tx that goes
 * through `/api/sponsor` would try to self-sponsor and collide with the
 * wallet's own gas-coin picking. When the connected address matches this,
 * we fall through to the wallet-pays path even on localnet.
 */
const DEPLOYER_ADDRESS = process.env.NEXT_PUBLIC_DEPLOYER_ADDRESS;

/**
 * useMutation wrapper that picks one of three tx submission paths, depending
 * on identity + network:
 *
 *  A. **localnet + non-deployer sender** — build a `TransactionKind`, POST
 *     to `/api/sponsor` (the deployer's key pays gas), ask the wallet to
 *     co-sign the same bytes, submit `[userSig, sponsorSig]`. Fully-
 *     sponsored UX for customers and extra cashier wallets.
 *  B. **testnet/mainnet + Enoki-registered wallet** — `/api/enoki-sponsor`
 *     wraps the kind as a sponsored tx (subject to the Enoki app's
 *     allowedMoveCallTargets rules), the Enoki wallet signs with the zkLogin
 *     keypair, `/api/enoki-execute` finalizes.
 *  C. **testnet/mainnet + any other wallet, OR localnet + deployer sender**
 *     — plain `useSignAndExecuteTransaction`, user pays gas. On localnet
 *     the deployer wallet was funded during bootstrap, so it has SUI to
 *     spend on its own txs.
 */
export function useSponsoredMutation<TArgs>(
  build: (tx: Transaction, args: TArgs) => void,
  opts: SponsorOptions = {},
) {
  const account = useCurrentAccount();
  const client = useSuiClient();
  const queryClient = useQueryClient();
  const { currentWallet } = useCurrentWallet();
  const { mutate: disconnectWallet } = useDisconnectWallet();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { mutateAsync: signOnly } = useSignTransaction();

  return useMutation({
    mutationFn: async (args: TArgs) => {
      if (!account) throw new Error("Connect a wallet first");
      const senderAddress = account.address;
      const enokiConnected = currentWallet ? isEnokiWallet(currentWallet) : false;

      const tx = new Transaction();
      build(tx, args);

      const useLocalSponsor =
        NETWORK === "localnet" && senderAddress !== DEPLOYER_ADDRESS;
      const useEnokiSponsor = NETWORK !== "localnet" && enokiConnected;
      let digest: string;

      if (useLocalSponsor) {
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

        // dapp-kit's `useSignTransaction` accepts a base64 string for
        // already-built tx bytes; `executeTransactionBlock` takes the same.
        const { signature: userSignature } = await signOnly({ transaction: bytes });

        const submitted = await client.executeTransactionBlock({
          transactionBlock: bytes,
          signature: [userSignature, sponsorSignature],
        });
        digest = submitted.digest;
      } else if (useEnokiSponsor) {
        // Server-side Enoki sponsorship. Two round-trips: create + execute.
        tx.setSenderIfNotSet(senderAddress);
        const kindBytes = await tx.build({ client, onlyTransactionKind: true });

        const createResp = await fetch("/api/enoki-sponsor", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            txKindBytes: toBase64(kindBytes),
            sender: senderAddress,
          }),
        });
        if (!createResp.ok) {
          const err = (await createResp.json().catch(() => null)) as {
            error?: string;
          } | null;
          throw new Error(err?.error ?? `enoki-sponsor failed (${createResp.status})`);
        }
        const { bytes, digest: sponsorDigest } = (await createResp.json()) as {
          bytes: string;
          digest: string;
        };

        // Enoki wallet signs the sponsor-wrapped bytes with its zkLogin
        // keypair. dapp-kit's `useSignTransaction` routes to the connected
        // wallet's own `signTransaction`.
        const { signature } = await signOnly({ transaction: bytes });

        const execResp = await fetch("/api/enoki-execute", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ digest: sponsorDigest, signature }),
        });
        if (!execResp.ok) {
          const err = (await execResp.json().catch(() => null)) as { error?: string } | null;
          throw new Error(err?.error ?? `enoki-execute failed (${execResp.status})`);
        }
        const executed = (await execResp.json()) as { digest: string };
        digest = executed.digest;
      } else {
        // Non-Enoki wallet on a shared chain: wallet pays gas.
        if (opts.gasBudget) tx.setGasBudget(opts.gasBudget);
        const result = await signAndExecute({ transaction: tx });
        digest = result.digest;
      }

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
      if (isEnokiSessionGone(err)) {
        // Wipe the wallet-standard connection so the next Log-in click starts
        // a fresh OAuth flow rather than trying to reuse the dead session.
        disconnectWallet();
        toast.error("Your Google sign-in expired — please log in again.");
        return;
      }
      toast.error(
        err instanceof Error ? err.message : "Transaction failed (unknown error)",
      );
    },
  });
}
