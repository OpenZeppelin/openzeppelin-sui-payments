"use client";

import { ConnectButton as DappKitConnectButton, useCurrentAccount } from "@mysten/dapp-kit";

import { shortAddr } from "@/lib/utils";

/**
 * Header login control. Delegates to dapp-kit's ConnectButton, which shows
 * every registered wallet — installed extension wallets (Slush, Suiet) plus
 * the Enoki-registered "Sign in with Google" entry (see `registerEnokiWallets`
 * in `providers.tsx`). When already connected, shows a short-form address;
 * dapp-kit handles the disconnect modal on click.
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
