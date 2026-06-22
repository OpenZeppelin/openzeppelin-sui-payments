import {
  Transaction,
  type TransactionArgument,
  type TransactionResult,
} from "@mysten/sui/transactions";

import { deployment } from "@/lib/deployment";

/**
 * `account::create_and_share(ns, addr)` — creates a customer's PAS Account
 * and shares it. PAS derives the account id deterministically from
 * (namespace, addr), so calling this is idempotent on the address but errors
 * if the account already exists.
 */
export function buildCreateAndShareAccount(tx: Transaction, ownerAddress: string): void {
  tx.moveCall({
    target: `${deployment.pasPackageId}::account::create_and_share`,
    arguments: [tx.object(deployment.namespaceId), tx.pure.address(ownerAddress)],
  });
}

/**
 * `account::account_address(ns, addr)` — pure function returning the deterministic
 * account address for a given owner. Useful when we don't know if an account
 * already exists; the UI can pre-compute the id and check via `getObject`.
 *
 * NOTE: this is a dev-time helper; in practice you'd compute the address
 * client-side rather than burning a tx slot on it.
 */
export function buildAccountAddress(tx: Transaction, ownerAddress: string): TransactionResult {
  return tx.moveCall({
    target: `${deployment.pasPackageId}::namespace::account_address`,
    arguments: [tx.object(deployment.namespaceId), tx.pure.address(ownerAddress)],
  });
}

/** `account::new_auth(ctx) -> Auth` — proof the caller controls the active address. */
export function buildAccountNewAuth(tx: Transaction): TransactionResult {
  return tx.moveCall({
    target: `${deployment.pasPackageId}::account::new_auth`,
  });
}

/**
 * `account::send_balance<T>(&auth, &dest_account, amount, ctx) -> Request<SendFunds<Balance<T>>>`.
 * The returned `Request` is a hot potato that gets stamped with approval (e.g.
 * by `stablecoin_mock::approve_transfer`) and then resolved inside
 * `merchant::pay<T>`.
 */
export function buildSendBalance(
  tx: Transaction,
  args: {
    auth: TransactionArgument;
    customerAccountId: string;
    destAccountId: string;
    amount: bigint;
    coinType: string;
  },
): TransactionResult {
  return tx.moveCall({
    target: `${deployment.pasPackageId}::account::send_balance`,
    typeArguments: [args.coinType],
    arguments: [
      tx.object(args.customerAccountId),
      args.auth,
      tx.object(args.destAccountId),
      tx.pure.u64(args.amount),
    ],
  });
}

/**
 * `account::unlock_balance<T>(&auth, amount, ctx) -> Request<UnlockFunds<Balance<T>>>`.
 * Used by `merchant::create_voucher` to extract a customer's LOYALTY balance into the Voucher.
 */
export function buildUnlockBalance(
  tx: Transaction,
  args: {
    auth: TransactionArgument;
    customerAccountId: string;
    amount: bigint;
    coinType: string;
  },
): TransactionResult {
  return tx.moveCall({
    target: `${deployment.pasPackageId}::account::unlock_balance`,
    typeArguments: [args.coinType],
    arguments: [
      tx.object(args.customerAccountId),
      args.auth,
      tx.pure.u64(args.amount),
    ],
  });
}
