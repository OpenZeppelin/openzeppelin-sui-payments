"use client";

import { useEffect, useRef, useState } from "react";
import {
  useConnectWallet,
  useCurrentAccount,
  useDisconnectWallet,
  useWallets,
} from "@mysten/dapp-kit";
import { isEnokiWallet } from "@mysten/enoki";

import { Button } from "@/components/ui/button";
import { shortAddr } from "@/lib/utils";

/**
 * Header login control. Custom wallet picker (replaces dapp-kit's built-in
 * `ConnectButton`) so we can:
 *   - Relabel entries to "Continue with X" — friendlier than the raw wallet
 *     names ("Sign in with Google", "Slush", …).
 *   - Sort Enoki-registered wallets (walletless zkLogin) to the top on
 *     testnet/mainnet, since that's the "user never sees a wallet" path
 *     the template is meant to demonstrate.
 *
 * Rendered as an anchored popover directly under the trigger button (not a
 * centered modal), so the login feels like part of the header rather than
 * a screen-blocking dialog.
 *
 * Connected state shows a short-form address plus a Log-out button.
 */

type Wallet = ReturnType<typeof useWallets>[number];

const PROVIDER_LABEL: Record<string, string> = {
  google: "Google",
  facebook: "Facebook",
  twitch: "Twitch",
};

function walletLabel(wallet: Wallet): string {
  if (isEnokiWallet(wallet)) {
    const name = PROVIDER_LABEL[wallet.provider] ?? wallet.provider;
    return `Continue with ${name}`;
  }
  return `Continue with ${wallet.name}`;
}

function sortWallets(wallets: readonly Wallet[]): Wallet[] {
  const enoki: Wallet[] = [];
  const others: Wallet[] = [];
  for (const w of wallets) (isEnokiWallet(w) ? enoki : others).push(w);
  others.sort((a, b) => a.name.localeCompare(b.name));
  return [...enoki, ...others];
}

export function ConnectButton() {
  const account = useCurrentAccount();
  const wallets = useWallets();
  const { mutate: connect, isPending } = useConnectWallet();
  const { mutate: disconnect } = useDisconnectWallet();
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  // Close on outside click + Escape when the popover is open.
  useEffect(() => {
    if (!open) return;
    function onPointerDown(e: PointerEvent) {
      if (!containerRef.current) return;
      if (!containerRef.current.contains(e.target as Node)) setOpen(false);
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  if (account) {
    return (
      <div className="flex items-center gap-3 text-sm">
        <span className="text-[color:var(--color-muted-foreground)]">
          {shortAddr(account.address)}
        </span>
        <Button size="sm" variant="outline" onClick={() => disconnect()}>
          Log out
        </Button>
      </div>
    );
  }

  const sorted = sortWallets(wallets);

  return (
    <div ref={containerRef} className="relative flex items-center">
      <Button size="sm" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        Log in
      </Button>
      {open ? (
        <div
          role="menu"
          className="absolute right-0 top-full z-50 mt-2 w-64 rounded-xl border border-[color:var(--color-border)] bg-[color:var(--color-card)] p-2 text-[color:var(--color-card-foreground)] shadow-lg"
        >
          {sorted.length === 0 ? (
            <p className="px-3 py-2 text-sm text-[color:var(--color-muted-foreground)]">
              No wallets available.
            </p>
          ) : (
            sorted.map((wallet) => (
              <button
                key={wallet.name}
                type="button"
                role="menuitem"
                disabled={isPending}
                onClick={() =>
                  connect({ wallet }, { onSuccess: () => setOpen(false) })
                }
                className="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left transition-colors hover:bg-[color:var(--color-muted)] focus-visible:bg-[color:var(--color-muted)] focus-visible:outline-none disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {wallet.icon ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={wallet.icon}
                    alt=""
                    aria-hidden
                    className="h-6 w-6 rounded"
                  />
                ) : (
                  <span
                    aria-hidden
                    className="h-6 w-6 rounded bg-[color:var(--color-muted)]"
                  />
                )}
                <span className="text-sm font-medium">{walletLabel(wallet)}</span>
              </button>
            ))
          )}
        </div>
      ) : null}
    </div>
  );
}
