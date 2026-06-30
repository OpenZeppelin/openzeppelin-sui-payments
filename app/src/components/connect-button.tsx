"use client";

import { ConnectButton as DappKitConnectButton, useCurrentAccount } from "@mysten/dapp-kit";

import { Button } from "@/components/ui/button";
import { GoogleLoginButton } from "@/components/google-login-button";
import { useZkLoginSession } from "@/hooks/use-zklogin-session";
import { shortAddr } from "@/lib/utils";

/**
 * Header login control. Two ways in:
 *   1. Google zkLogin (custom flow, works on any network including localnet).
 *   2. dapp-kit wallet modal — extension wallets, plus the Enoki-registered
 *      "Log in with Google" entry on testnet/mainnet.
 *
 * If a zkLogin session is active it takes priority (shows the derived address
 * + a Log-out button). Otherwise both entry points are offered side by side.
 */
export function ConnectButton() {
  const account = useCurrentAccount();
  const { session, logout } = useZkLoginSession();

  if (session) {
    return (
      <div className="flex items-center gap-3 text-sm">
        <span className="text-[color:var(--color-muted-foreground)]">
          {shortAddr(session.address)} · Google
        </span>
        <Button size="sm" variant="outline" onClick={logout}>
          Log out
        </Button>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-3 text-sm">
      {account ? (
        <span className="text-[color:var(--color-muted-foreground)]">
          {shortAddr(account.address)}
        </span>
      ) : null}
      <DappKitConnectButton connectText="Log in" />
      <GoogleLoginButton />
    </div>
  );
}
