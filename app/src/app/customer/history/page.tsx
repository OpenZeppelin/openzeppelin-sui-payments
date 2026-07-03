"use client";

import { useState } from "react";
import { useCurrentAccount } from "@mysten/dapp-kit";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useListings, useReceipts } from "@/hooks/queries";
import { formatAmount, formatItems, shortAddr } from "@/lib/utils";
import type { Listing } from "@/lib/move/types";

type Tab = "payments" | "redemptions";

export default function HistoryPage() {
  const address = useCurrentAccount()?.address ?? null;
  // Poll while the page is open — the merchant's redeem tx happens in a
  // different browser session, so cross-client React-Query invalidation
  // isn't an option.
  const receipts = useReceipts(address, { pollMs: 5_000 });
  const { data: listings = [] } = useListings();
  const [tab, setTab] = useState<Tab>("payments");

  return (
    <section>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">History</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          On-chain settlements attributed to your address. Source of truth is
          the event stream; receipts live on the merchant.
        </p>
      </header>

      <div className="mb-4 flex gap-2">
        <Button
          variant={tab === "payments" ? "default" : "ghost"}
          onClick={() => setTab("payments")}
        >
          Payments
        </Button>
        <Button
          variant={tab === "redemptions" ? "default" : "ghost"}
          onClick={() => setTab("redemptions")}
        >
          Redemptions
        </Button>
      </div>

      {!address ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Log in to view your history.
        </p>
      ) : receipts.isLoading ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading…</p>
      ) : tab === "payments" ? (
        <PaymentList rows={receipts.data?.payment ?? []} listings={listings} />
      ) : (
        <RedemptionList rows={receipts.data?.redemption ?? []} listings={listings} />
      )}
    </section>
  );
}

function PaymentList({
  rows,
  listings,
}: {
  rows: ReturnType<typeof useReceipts>["data"] extends infer R
    ? R extends { payment: infer P }
      ? P
      : never
    : never;
  listings: readonly Listing[];
}) {
  if (rows.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-[color:var(--color-border)] p-12 text-center text-sm text-[color:var(--color-muted-foreground)]">
        No payments yet. Pay an invoice from <strong>Scan to pay</strong>.
      </div>
    );
  }
  return (
    <Card>
      <CardHeader>
        <CardTitle>{rows.length} payment{rows.length === 1 ? "" : "s"}</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="divide-y divide-[color:var(--color-border)]">
          {rows.map((r) => {
            const orderRef = new TextDecoder().decode(new Uint8Array(r.orderRef));
            const when = new Date(Number(r.timestampMs)).toLocaleString();
            return (
              <div key={r.invoiceId} className="flex items-center justify-between gap-4 py-3">
                <div className="flex items-center gap-3">
                  <Badge variant="accent">Paid</Badge>
                  <div>
                    <div className="text-sm font-medium">
                      {formatAmount(r.amount, 6)} USD · {r.loyalty.toString()} LOY earned
                    </div>
                    <div className="text-xs text-[color:var(--color-muted-foreground)]">
                      {formatItems(r.items, listings)}
                      {orderRef ? ` · ${orderRef}` : ""} ·{" "}
                      <span className="font-mono">{shortAddr(r.invoiceId, 6)}</span>
                    </div>
                  </div>
                </div>
                <div className="text-xs text-[color:var(--color-muted-foreground)]">{when}</div>
              </div>
            );
          })}
        </div>
      </CardContent>
    </Card>
  );
}

function RedemptionList({
  rows,
  listings,
}: {
  rows: ReturnType<typeof useReceipts>["data"] extends infer R
    ? R extends { redemption: infer P }
      ? P
      : never
    : never;
  listings: readonly Listing[];
}) {
  if (rows.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-[color:var(--color-border)] p-12 text-center text-sm text-[color:var(--color-muted-foreground)]">
        No redemptions yet. Create a voucher from <strong>Rewards</strong>.
      </div>
    );
  }
  return (
    <Card>
      <CardHeader>
        <CardTitle>{rows.length} redemption{rows.length === 1 ? "" : "s"}</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="divide-y divide-[color:var(--color-border)]">
          {rows.map((r) => {
            const when = new Date(Number(r.timestampMs)).toLocaleString();
            return (
              <div key={r.voucherId} className="flex items-center justify-between gap-4 py-3">
                <div className="flex items-center gap-3">
                  <Badge variant="default">Redeemed</Badge>
                  <div>
                    <div className="text-sm font-medium">
                      {r.amount.toString()} LOY burned
                    </div>
                    <div className="text-xs text-[color:var(--color-muted-foreground)]">
                      {formatItems(r.items, listings)} ·{" "}
                      <span className="font-mono">{shortAddr(r.voucherId, 6)}</span>
                    </div>
                  </div>
                </div>
                <div className="text-xs text-[color:var(--color-muted-foreground)]">{when}</div>
              </div>
            );
          })}
        </div>
      </CardContent>
    </Card>
  );
}
