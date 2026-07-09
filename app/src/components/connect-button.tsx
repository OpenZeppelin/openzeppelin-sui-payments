"use client";

import { useEffect, useRef, useState } from "react";
import {
  useAccounts,
  useConnectWallet,
  useCurrentAccount,
  useDisconnectWallet,
  useSwitchAccount,
  useWallets,
} from "@mysten/dapp-kit";
import { Check, ChevronDown } from "lucide-react";
import { isEnokiWallet } from "@mysten/enoki";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { shortAddr } from "@/lib/utils";

/**
 * Header login control. Custom picker (replaces dapp-kit's built-in
 * `ConnectButton`) so we can:
 *   - Relabel entries to "Continue with X" — friendlier than the raw wallet
 *     names ("Sign in with Google", "Slush", …).
 *   - Sort Enoki-registered wallets (walletless zkLogin) to the top on
 *     testnet/mainnet.
 *   - Let a connected user switch between accounts the wallet exposes
 *     (wallets like Slush hold multiple accounts; the disconnected state
 *     is a wallet picker, the connected state is an account switcher).
 *
 * Both modes render as an anchored popover directly under the trigger button
 * (not a centered modal), so the login feels like part of the header rather
 * than a screen-blocking dialog.
 */

type Wallet = ReturnType<typeof useWallets>[number];
type Account = ReturnType<typeof useAccounts>[number];

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

/**
 * Shared anchored-popover primitive: click-outside + Escape close, focus into
 * the first menu item on open, focus back to the trigger on close. Callers
 * wire `triggerRef` on the button that opens the menu and `containerRef` on
 * the popover's outer element (`role="menu"`).
 */
function useAnchoredPopover(): {
  containerRef: React.RefObject<HTMLDivElement | null>;
  triggerRef: React.RefObject<HTMLButtonElement | null>;
  open: boolean;
  setOpen: (next: boolean) => void;
} {
  const containerRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const wasOpenRef = useRef(false);

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
    // Autofocus the first menu item once the popover mounts. Uses
    // `requestAnimationFrame` so the DOM has painted before we look for it.
    const raf = requestAnimationFrame(() => {
      const first = containerRef.current?.querySelector<HTMLElement>('[role="menuitem"]');
      first?.focus();
    });
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKey);
      cancelAnimationFrame(raf);
    };
  }, [open]);

  // On close, restore focus to the trigger — but only when we're closing after
  // having been open (not on initial mount).
  useEffect(() => {
    if (!open && wasOpenRef.current) {
      triggerRef.current?.focus();
    }
    wasOpenRef.current = open;
  }, [open]);

  return { containerRef, triggerRef, open, setOpen };
}

/** Arrow/Home/End keyboard nav across all `[role="menuitem"]` in the menu. */
function onMenuKey(e: React.KeyboardEvent<HTMLDivElement>) {
  const items = Array.from(
    e.currentTarget.querySelectorAll<HTMLElement>('[role="menuitem"]:not([disabled])'),
  );
  if (items.length === 0) return;
  const active = document.activeElement as HTMLElement | null;
  const idx = active ? items.indexOf(active) : -1;
  let next = -1;
  if (e.key === "ArrowDown") next = idx < 0 ? 0 : (idx + 1) % items.length;
  else if (e.key === "ArrowUp") next = idx <= 0 ? items.length - 1 : idx - 1;
  else if (e.key === "Home") next = 0;
  else if (e.key === "End") next = items.length - 1;
  if (next >= 0) {
    e.preventDefault();
    items[next].focus();
  }
}

export function ConnectButton() {
  const account = useCurrentAccount();
  return account ? <ConnectedControl /> : <DisconnectedControl />;
}

function DisconnectedControl() {
  const wallets = useWallets();
  const { mutate: connect, isPending } = useConnectWallet();
  const { containerRef, triggerRef, open, setOpen } = useAnchoredPopover();
  const sorted = sortWallets(wallets);

  return (
    <div ref={containerRef} className="relative flex items-center">
      <Button
        ref={triggerRef}
        size="sm"
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        aria-haspopup="menu"
      >
        Log in
      </Button>
      {open ? (
        <div
          role="menu"
          onKeyDown={onMenuKey}
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
                  connect(
                    { wallet },
                    {
                      onSuccess: () => setOpen(false),
                      // Popup cancels surface here too ("User rejected …") —
                      // fine to surface: the user just clicked X, a brief
                      // toast confirms nothing happened silently.
                      onError: (err) =>
                        toast.error(err instanceof Error ? err.message : "Connect failed"),
                    },
                  )
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

function ConnectedControl() {
  const account = useCurrentAccount()!;
  const accounts = useAccounts();
  const { mutate: switchAccount } = useSwitchAccount();
  const { mutate: disconnect } = useDisconnectWallet();
  const { containerRef, triggerRef, open, setOpen } = useAnchoredPopover();
  const multiAccount = accounts.length > 1;

  return (
    <div className="flex items-center gap-3 text-sm">
      <div ref={containerRef} className="relative flex items-center">
        {multiAccount ? (
          <button
            ref={triggerRef}
            type="button"
            onClick={() => setOpen(!open)}
            aria-expanded={open}
            aria-haspopup="menu"
            className="flex items-center gap-2 rounded-md px-2 py-1 text-[color:var(--color-muted-foreground)] transition-colors hover:bg-[color:var(--color-muted)] focus-visible:bg-[color:var(--color-muted)] focus-visible:outline-none"
          >
            <span className="font-mono">{shortAddr(account.address)}</span>
            <ChevronDown className="h-3.5 w-3.5" />
          </button>
        ) : (
          <span className="px-2 font-mono text-[color:var(--color-muted-foreground)]">
            {shortAddr(account.address)}
          </span>
        )}
        {multiAccount && open ? (
          <div
            role="menu"
            onKeyDown={onMenuKey}
            className="absolute right-0 top-full z-50 mt-2 w-72 rounded-xl border border-[color:var(--color-border)] bg-[color:var(--color-card)] p-2 text-[color:var(--color-card-foreground)] shadow-lg"
          >
            <div className="px-3 pb-1 pt-2 text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
              Accounts
            </div>
            {accounts.map((a) => (
              <AccountRow
                key={a.address}
                account={a}
                current={a.address === account.address}
                onSelect={() => {
                  switchAccount(
                    { account: a },
                    {
                      onSuccess: () => setOpen(false),
                      onError: (err) =>
                        toast.error(err instanceof Error ? err.message : "Switch failed"),
                    },
                  );
                }}
              />
            ))}
          </div>
        ) : null}
      </div>
      <Button size="sm" variant="outline" onClick={() => disconnect()}>
        Log out
      </Button>
    </div>
  );
}

function AccountRow({
  account,
  current,
  onSelect,
}: {
  account: Account;
  current: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onSelect}
      className="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left transition-colors hover:bg-[color:var(--color-muted)] focus-visible:bg-[color:var(--color-muted)] focus-visible:outline-none"
    >
      <span className="flex h-4 w-4 items-center justify-center text-[color:var(--color-primary)]">
        {current ? <Check className="h-4 w-4" /> : null}
      </span>
      <div className="min-w-0 flex-1">
        {account.label ? (
          <div className="truncate text-sm font-medium">{account.label}</div>
        ) : null}
        <div className="truncate font-mono text-xs text-[color:var(--color-muted-foreground)]">
          {shortAddr(account.address, 8)}
        </div>
      </div>
    </button>
  );
}
