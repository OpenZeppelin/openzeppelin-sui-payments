"use client";

import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { fromBase64, toBase64 } from "@mysten/sui/utils";

type SignTransactionFn = (input: {
  transaction: Transaction;
}) => Promise<{ bytes: string; signature: string }>;

export interface SponsorAndExecuteArgs {
  /** The PTB to sponsor + execute. Sender and gas data are filled in for you. */
  transaction: Transaction;
  /** Customer's address (the signer / sender). */
  sender: string;
  /** Wallet signing function from dapp-kit's `useSignTransaction()` mutation. */
  signTransaction: SignTransactionFn;
  /** SuiClient (from `useSuiClient()`). */
  client: SuiClient;
  /** Optional gas budget override (MIST as a stringified bigint). */
  gasBudget?: bigint;
}

/**
 * Orchestrates the three-step sponsored transaction dance:
 *   1. Client builds a TransactionKind (no sender / no gas).
 *   2. POSTs to /api/sponsor — server attaches gas, signs as gas-payer,
 *      returns full transaction bytes + sponsor signature.
 *   3. Client asks the wallet to sign the same bytes, then submits both
 *      signatures to the chain.
 *
 * The customer never pays gas; they only sign the transaction with their
 * (Enoki-zkLogin) wallet.
 */
export async function sponsorAndExecute({
  transaction,
  sender,
  signTransaction,
  client,
  gasBudget,
}: SponsorAndExecuteArgs) {
  // 1. Build the inner TransactionKind. `onlyTransactionKind: true` strips
  // sender + gasData; the server fills those in.
  const txKindBytes = await transaction.build({
    client,
    onlyTransactionKind: true,
  });

  // 2. Ask the server to sponsor it: server attaches its gas data + signs.
  const resp = await fetch("/api/sponsor", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      txKindBytes: toBase64(txKindBytes),
      sender,
      gasBudget: gasBudget?.toString(),
    }),
  });
  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`/api/sponsor failed: ${resp.status} ${err}`);
  }
  const { txBytes, sponsorSignature } = (await resp.json()) as {
    txBytes: string;
    sponsorSignature: string;
  };

  // 3. Sender signs the SAME bytes. Some wallets re-build the tx during
  // signing and return slightly different bytes — if those bytes don't match
  // what the sponsor signed, Sui rejects the submission with either a
  // signature-count error ("Expect 1 signer signatures but got 2", when the
  // wallet stripped the sponsor's gasData) or an invalid-signature error.
  // Compare and fail fast with a clear message rather than letting Sui's
  // validator produce a cryptic one.
  const fullTx = Transaction.from(fromBase64(txBytes));
  const { bytes: signedBytes, signature: senderSignature } = await signTransaction({
    transaction: fullTx,
  });
  if (signedBytes !== txBytes) {
    throw new Error(
      "Wallet re-built the sponsored transaction and changed its bytes. " +
        "The sponsor's signature is no longer valid for what the wallet signed. " +
        "Switch to a wallet that preserves the gas data of an already-built " +
        "sponsored transaction (Slush, most Sui browser extensions). zkLogin " +
        "wallets that auto-attach their own gas need the two-step sponsor flow.",
    );
  }

  // 4. Submit with both signatures.
  return client.executeTransactionBlock({
    transactionBlock: signedBytes,
    signature: [senderSignature, sponsorSignature],
    options: {
      showEffects: true,
      showEvents: true,
      showObjectChanges: true,
    },
  });
}
