import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { fromBase64, toBase64 } from "@mysten/sui/utils";

import { sponsorKeypair } from "@/lib/sponsor-server";
import { NETWORK, networkConfig } from "@/lib/sui-client";

const DEFAULT_GAS_BUDGET = 100_000_000n; // 0.1 SUI

type SponsorRequestBody = {
  /** Base64 of `tx.build({ onlyTransactionKind: true })`. */
  txKindBytes: string;
  /** Sender (customer) address — Sui hex string. */
  sender: string;
  /** Optional gas budget override (MIST as a stringified bigint). */
  gasBudget?: string;
};

type SponsorResponseBody = {
  /** Base64 of the fully-built transaction including sponsor's gasData. */
  txBytes: string;
  /** Sponsor's signature over `txBytes`. */
  sponsorSignature: string;
  /** Sponsor address (for client debugging). */
  sponsor: string;
};

/**
 * POST /api/sponsor
 *
 * Receives a TransactionKind (the inner programmable transaction) from the
 * client, wraps it into a full sponsored Transaction by attaching the
 * sponsor's gas payment, signs as gas-payer, and returns:
 *
 *   { txBytes, sponsorSignature }
 *
 * The client then asks the user's wallet to sign the same `txBytes` and
 * submits both signatures via `client.executeTransactionBlock`.
 *
 * Allowlisting: this route does NOT inspect the transaction's MoveCalls.
 * For production you'd validate that the calls target package IDs / functions
 * you actually want to sponsor — otherwise the route happily pays gas for
 * anyone's transaction. Tracked as a future hardening item.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  let body: SponsorRequestBody;
  try {
    body = (await req.json()) as SponsorRequestBody;
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  if (!body.txKindBytes || !body.sender) {
    return NextResponse.json(
      { error: "txKindBytes and sender are required" },
      { status: 400 },
    );
  }

  const sponsor = sponsorKeypair();
  const sponsorAddr = sponsor.toSuiAddress();
  const client = new SuiClient({ url: networkConfig[NETWORK].url });

  // Sui considers a transaction "sponsored" only when `gas_data.owner != sender`.
  // If the connected wallet happens to be the sponsor address (e.g. someone
  // imported the sponsor key into Slush), we'd build a tx where owner == sender,
  // and Sui's validator would expect exactly one signature — but we attach two
  // (sender + sponsor), producing "Expect 1 signer signatures but got 2".
  // Fail fast with a clear message.
  if (body.sender.toLowerCase() === sponsorAddr.toLowerCase()) {
    return NextResponse.json(
      {
        error:
          `Connected wallet (${body.sender}) is the same address as the ` +
          `sponsor (${sponsorAddr}). Connect a different wallet — the sponsor ` +
          `must be a separate address from the transaction sender.`,
      },
      { status: 400 },
    );
  }

  // Pick a gas coin owned by the sponsor.
  const { data: coins } = await client.getCoins({
    owner: sponsorAddr,
    coinType: "0x2::sui::SUI",
  });
  if (coins.length === 0) {
    return NextResponse.json(
      { error: `sponsor account ${sponsorAddr} has no SUI gas coins — fund it via the faucet` },
      { status: 500 },
    );
  }
  // Use the largest coin as payment (avoids unnecessary splits / merges).
  const gasCoin = coins.reduce((a, b) =>
    BigInt(a.balance) >= BigInt(b.balance) ? a : b,
  );

  // Reconstruct a Transaction from the client-supplied kind bytes and attach
  // sponsor-owned gas info.
  const tx = Transaction.fromKind(fromBase64(body.txKindBytes));
  tx.setSender(body.sender);
  tx.setGasOwner(sponsorAddr);
  tx.setGasPayment([
    {
      objectId: gasCoin.coinObjectId,
      version: gasCoin.version,
      digest: gasCoin.digest,
    },
  ]);
  tx.setGasBudget(body.gasBudget ? BigInt(body.gasBudget) : DEFAULT_GAS_BUDGET);

  // Build to final TransactionData bytes (with all gas fields populated).
  const txBytes = await tx.build({ client });

  // Sign as gas payer.
  const { signature: sponsorSignature } = await sponsor.signTransaction(txBytes);

  const response: SponsorResponseBody = {
    txBytes: toBase64(txBytes),
    sponsorSignature,
    sponsor: sponsorAddr,
  };
  return NextResponse.json(response);
}
