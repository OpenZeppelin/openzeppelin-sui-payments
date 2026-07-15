"use client";

import Link from "next/link";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { Coins, Gift, History, QrCode, Wallet } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { useBalances, useListings, useReceipts } from "@/hooks/queries";
import { usePasAccount } from "@/hooks/use-pas-account";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { deployment } from "@/lib/deployment";
import { buildCreateAndShareAccount } from "@/lib/move/pas";
import { STABLECOIN_DECIMALS, formatAmount, formatItems, shortAddr } from "@/lib/utils";

const cards = [
  {
    href: "/customer/pay",
    title: "Scan to pay",
    icon: QrCode,
    description: "Scan a merchant invoice QR or paste an ID to settle.",
  },
  {
    href: "/customer/topup",
    title: "Top up",
    icon: Coins,
    description: "Fund your stablecoin balance (demo faucet).",
  },
  {
    href: "/customer/rewards",
    title: "Rewards",
    icon: Gift,
    description: "Spend loyalty points on free items via a voucher.",
  },
  {
    href: "/customer/history",
    title: "History",
    icon: History,
    description: "Past payments and redemptions attributed to you.",
  },
];

export default function CustomerPage() {
  const address = useCurrentAccount()?.address ?? null;
  const pas = usePasAccount(address);
  const balances = useBalances(pas.data ?? null, [
    deployment.stablecoinType,
    deployment.loyaltyType,
  ]);

  // `create_and_share` doesn't take an `&Auth` — anyone with gas can create
  // the account for any address. The customer signs their own init tx and
  // gas is sponsored (localnet gas station on localnet, Enoki on testnet with
  // the Enoki wallet, wallet-paid otherwise) — so no deployer involvement.
  const initAccount = useSponsoredMutation<{ ownerAddress: string }>(
    (tx, args) => buildCreateAndShareAccount(tx, args.ownerAddress),
    {
      invalidate: [["pas-account", address ?? ""]],
      successMessage: "Account initialized",
    },
  );

  const stable = balances.data?.[deployment.stablecoinType] ?? 0n;
  const loyalty = balances.data?.[deployment.loyaltyType] ?? 0n;

  const connected = Boolean(address);
  const accountExists = pas.data !== null && pas.data !== undefined;
  const ready = connected && accountExists;

  return (
    <section className="flex flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold">Customer</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Pay merchants, earn loyalty, redeem rewards — gas-free.
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardDescription>Your balance</CardDescription>
          <CardTitle className="font-mono text-sm">
            {address ? shortAddr(address, 8) : "Not connected"}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {!connected ? (
            <p className="text-sm text-[color:var(--color-muted-foreground)]">
              Connect a wallet (top right) to see your balance.
            </p>
          ) : pas.isLoading ? (
            <p className="text-sm text-[color:var(--color-muted-foreground)]">
              Looking up your PAS account…
            </p>
          ) : !accountExists ? (
            <div className="flex flex-col items-start gap-3">
              <p className="text-sm text-[color:var(--color-muted-foreground)]">
                You don&apos;t have a PAS account on this network yet. It holds
                your stablecoin and loyalty balances and proves your identity
                for payments. Creating it is gas-free.
              </p>
              <Button
                onClick={() =>
                  initAccount.mutate(
                    { ownerAddress: address! },
                    { onSuccess: () => pas.refetch() },
                  )
                }
                disabled={initAccount.isPending}
              >
                <Wallet className="h-4 w-4" />
                {initAccount.isPending ? "Initializing…" : "Initialize account"}
              </Button>
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-6">
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Stablecoin
                </div>
                <div className="mt-1 text-3xl font-semibold">
                  {balances.isLoading ? "…" : formatAmount(stable, 6)}{" "}
                  <span className="text-base font-normal">USD</span>
                </div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Loyalty
                </div>
                <div className="mt-1 text-3xl font-semibold">
                  {balances.isLoading ? "…" : formatAmount(loyalty, 0)}{" "}
                  <span className="text-base font-normal">LOY</span>
                </div>
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        {cards.map(({ href, title, icon: Icon, description }) => {
          const card = (
            <Card
              className={
                ready
                  ? "transition-transform hover:-translate-y-0.5 hover:shadow-md"
                  : "opacity-50"
              }
            >
              <CardHeader>
                <Icon className="h-7 w-7 text-[color:var(--color-primary)]" />
                <CardTitle>{title}</CardTitle>
                <CardDescription>{description}</CardDescription>
              </CardHeader>
            </Card>
          );
          return ready ? (
            <Link key={href} href={href}>
              {card}
            </Link>
          ) : (
            <div key={href} aria-disabled className="cursor-not-allowed">
              {card}
            </div>
          );
        })}
      </div>

      {ready ? <RecentTransactions address={address!} /> : null}
    </section>
  );
}

/**
 * Compact recent-activity block under the action cards on the customer home.
 * Merges the last few payments + redemptions attributed to the current
 * address, sorted newest-first, capped at MAX_ROWS. Full detail lives on
 * `/customer/history` (link at the bottom of the card).
 */
function RecentTransactions({ address }: { address: string }) {
  const MAX_ROWS = 5;
  const receipts = useReceipts(address, { pollMs: 5_000 });
  const { data: listings = [] } = useListings();

  type Row =
    | { kind: "payment"; id: string; when: bigint; label: string; sub: string }
    | { kind: "redemption"; id: string; when: bigint; label: string; sub: string };

  const rows: Row[] = [];
  for (const r of receipts.data?.payment ?? []) {
    const orderRef = new TextDecoder().decode(new Uint8Array(r.orderRef));
    const itemLabel = formatItems(r.items, listings);
    rows.push({
      kind: "payment",
      id: r.invoiceId,
      when: r.timestampMs,
      label: `${formatAmount(r.amount, STABLECOIN_DECIMALS)} USD · ${r.loyalty.toString()} LOY earned`,
      sub: `${itemLabel}${orderRef ? ` · ${orderRef}` : ""}`,
    });
  }
  for (const r of receipts.data?.redemption ?? []) {
    rows.push({
      kind: "redemption",
      id: r.voucherId,
      when: r.timestampMs,
      label: `${r.amount.toString()} LOY burned`,
      sub: formatItems(r.items, listings),
    });
  }
  rows.sort((a, b) => Number(b.when - a.when));
  const top = rows.slice(0, MAX_ROWS);

  return (
    <Card>
      <CardHeader>
        <CardTitle>Recent transactions</CardTitle>
        <CardDescription>
          Last {MAX_ROWS} payments and redemptions attributed to your address.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {receipts.isLoading && !receipts.data ? (
          <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading…</p>
        ) : receipts.isError ? (
          <p className="text-sm text-[color:var(--color-destructive)]">
            Could not load activity: {receipts.error?.message ?? "unknown error"}
          </p>
        ) : top.length === 0 ? (
          <p className="text-sm text-[color:var(--color-muted-foreground)]">
            No activity yet. Pay an invoice or redeem a voucher to see it here.
          </p>
        ) : (
          <div className="divide-y divide-[color:var(--color-border)]">
            {top.map((r) => (
              <div key={`${r.kind}:${r.id}`} className="flex items-center justify-between gap-4 py-3">
                <div className="flex items-center gap-3">
                  <Badge variant={r.kind === "payment" ? "accent" : "default"}>
                    {r.kind === "payment" ? "Paid" : "Redeemed"}
                  </Badge>
                  <div>
                    <div className="text-sm font-medium">{r.label}</div>
                    <div className="text-xs text-[color:var(--color-muted-foreground)]">
                      {r.sub} · <span className="font-mono">{shortAddr(r.id, 6)}</span>
                    </div>
                  </div>
                </div>
                <div className="text-xs text-[color:var(--color-muted-foreground)]">
                  {new Date(Number(r.when)).toLocaleString()}
                </div>
              </div>
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
