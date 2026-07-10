import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { fromBase64, toBase64 } from "@mysten/sui/utils";

import { deployerAddress, deployerKeypair } from "@/lib/deployer-server";
import { NETWORK, networkConfig } from "@/lib/sui-client";

type SponsorRequestBody = {
  /** Base64-encoded `TransactionKind` bytes (built with `onlyTransactionKind: true`). */
  txKindBytes: string;
  /** The user wallet that will co-sign the tx after this route signs the gas leg. */
  sender: string;
};

type SponsorResponseBody = {
  /** Base64-encoded full `TransactionData` bytes for the wallet to sign. */
  bytes: string;
  /** Bech32 sponsor signature over `bytes`. */
  sponsorSignature: string;
};

const GAS_BUDGET = 50_000_000n;

/**
 * POST /api/sponsor
 *
 * Localnet gas station. Takes a client-built `TransactionKind` (no gas set),
 * wraps it as a sponsored `TransactionData` with the deployer account paying
 * gas, and returns the bytes + sponsor signature. The client then asks the
 * user's wallet to co-sign the same bytes and submits `[userSig,
 * sponsorSignature]` to the chain.
 *
 * The deployer doubles as the localnet gas sponsor — there's no separate
 * SPONSOR_PRIVATE_KEY. Two constraints follow:
 *   - Deployer-signed txs are refused here (400). Sponsoring yourself
 *     collides with the wallet's own gas-coin selection; the client's
 *     `useSponsoredMutation` already routes deployer-sent txs to the
 *     wallet-pays path, so hitting this branch means an env mismatch.
 *   - Localnet only. testnet/mainnet sponsorship is handled by Enoki via
 *     the connected wallet; this route hard-aborts unless `NETWORK ===
 *     "localnet"`.
 */
export async function POST(req: NextRequest): Promise<NextResponse> {
  if (NETWORK !== "localnet") {
    return NextResponse.json(
      {
        error:
          "/api/sponsor is a localnet-only gas station and is disabled outside " +
          "localnet. On testnet/mainnet, sponsor via Enoki through the connected " +
          "wallet.",
      },
      { status: 410 },
    );
  }

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
  if (body.sender === deployerAddress()) {
    return NextResponse.json(
      {
        error:
          "sender is the deployer address — deployer-signed txs must pay their " +
          "own gas (self-sponsorship collides with wallet gas selection). The " +
          "client should have routed this through the wallet-pays path.",
      },
      { status: 400 },
    );
  }

  const client = new SuiClient({ url: networkConfig[NETWORK].url });
  const sponsor = deployerKeypair();

  // Reconstruct the client-built TransactionKind, then add sender + gas leg.
  let tx: Transaction;
  try {
    tx = Transaction.fromKind(fromBase64(body.txKindBytes));
  } catch (err) {
    return NextResponse.json(
      { error: `could not parse txKindBytes: ${err instanceof Error ? err.message : err}` },
      { status: 400 },
    );
  }
  tx.setSender(body.sender);
  tx.setGasOwner(deployerAddress());
  tx.setGasBudget(GAS_BUDGET);

  // Build → returns the full TransactionData bytes that both parties sign.
  let bytes: Uint8Array;
  try {
    bytes = await tx.build({ client });
  } catch (err) {
    return NextResponse.json(
      { error: `tx build failed: ${err instanceof Error ? err.message : err}` },
      { status: 500 },
    );
  }
  const { signature: sponsorSignature } = await sponsor.signTransaction(bytes);

  const response: SponsorResponseBody = {
    bytes: toBase64(bytes),
    sponsorSignature,
  };
  return NextResponse.json(response);
}
