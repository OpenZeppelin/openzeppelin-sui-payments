"use client";

import { useState } from "react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useReceipts } from "@/hooks/queries";
import { useSessionAddress } from "@/hooks/use-session-address";
import { formatAmount, shortAddr } from "@/lib/utils";

type Tab = "payments" | "redemptions";

export default function HistoryPage() {
  const address = useSessionAddress();
  const receipts = useReceipts(address);
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
        <PaymentList rows={receipts.data?.payment ?? []} />
      ) : (
        <RedemptionList rows={receipts.data?.redemption ?? []} />
      )}
    </section>
  );
}

function PaymentList({
  rows,
}: {
  rows: ReturnType<typeof useReceipts>["data"] extends infer R
    ? R extends { payment: infer P }
      ? P
      : never
    : never;
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
                      {r.items.length} item{r.items.length === 1 ? "" : "s"}
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
}: {
  rows: ReturnType<typeof useReceipts>["data"] extends infer R
    ? R extends { redemption: infer P }
      ? P
      : never
    : never;
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
                      {r.items.length} item{r.items.length === 1 ? "" : "s"} ·{" "}
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
