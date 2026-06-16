"use client";

import { ConnectButton as DappKitConnectButton, useCurrentAccount } from "@mysten/dapp-kit";

import { shortAddr } from "@/lib/utils";

/**
 * Wraps dapp-kit's `ConnectButton`. With Enoki wallets registered (see
 * `providers.tsx`), "Login with Google" appears as a wallet entry in the
 * standard modal — same UI affordance as connecting any other Sui wallet.
 *
 * When already connected, shows a short-form address. dapp-kit handles the
 * disconnect modal itself on click.
 */
export function ConnectButton() {
  const account = useCurrentAccount();
  return (
    <div className="flex items-center gap-3 text-sm">
      {account ? (
        <span className="text-[color:var(--color-muted-foreground)]">
          {shortAddr(account.address)}
        </span>
      ) : null}
      <DappKitConnectButton connectText="Log in" />
    </div>
  );
}
