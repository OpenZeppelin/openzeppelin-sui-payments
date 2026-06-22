import { Transaction, type TransactionArgument } from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";

/**
 * `stablecoin_mock::approve_transfer(send_request)` — stamps the permissive
 * `TransferApproval` witness on a pending `Request<SendFunds<Balance<STABLE>>>`
 * so it can be resolved by `merchant::pay`. Mutates the request in place; the
 * same arg can flow into `merchant::pay` after.
 */
export function buildApproveTransfer(tx: Transaction, sendRequest: TransactionArgument): void {
  tx.moveCall({
    target: `${deployment.stablecoinPackageId}::stablecoin_mock::approve_transfer`,
    arguments: [sendRequest],
  });
}

/**
 * `stablecoin_mock::faucet(cap, recipient_account, amount)` — devnet-only mint
 * straight into a customer's PAS Account. Requires the deployer-held
 * `TreasuryCap<STABLECOIN_MOCK>`. Used by the customer "Top up" flow.
 */
export function buildFaucet(
  tx: Transaction,
  args: { treasuryCapId: string; recipientAccountId: string; amount: bigint },
): void {
  tx.moveCall({
    target: `${deployment.stablecoinPackageId}::stablecoin_mock::faucet`,
    arguments: [
      tx.object(args.treasuryCapId),
      tx.object(args.recipientAccountId),
      tx.pure.u64(args.amount),
    ],
  });
}
