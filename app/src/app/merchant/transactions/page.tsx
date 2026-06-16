"use client";

import { useMemo } from "react";

import { InvoiceQrButton } from "@/components/merchant/invoice-qr-button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useEvents, useInvoice } from "@/hooks/queries";
import { shortAddr } from "@/lib/utils";

type EventName =
  | "InvoiceCreated"
  | "InvoicePaid"
  | "InvoiceCanceled"
  | "VoucherCreated"
  | "VoucherRedeemed"
  | "VoucherCanceled";

interface FeedRow {
  name: EventName;
  digest: string;
  timestampMs: bigint;
  data: Record<string, unknown>;
}

function rowsFrom(
  name: EventName,
  events: { digest: string; timestampMs: bigint | null; parsed: Record<string, unknown> }[],
): FeedRow[] {
  return events.map((e) => ({
    name,
    digest: e.digest,
    timestampMs: e.timestampMs ?? 0n,
    data: e.parsed,
  }));
}

const variants: Record<
  EventName,
  { label: string; variant: "default" | "accent" | "muted" | "destructive" | "outline" }
> = {
  InvoiceCreated: { label: "Invoice open", variant: "outline" },
  InvoicePaid: { label: "Paid", variant: "accent" },
  InvoiceCanceled: { label: "Invoice canceled", variant: "muted" },
  VoucherCreated: { label: "Voucher open", variant: "outline" },
  VoucherRedeemed: { label: "Voucher redeemed", variant: "default" },
  VoucherCanceled: { label: "Voucher canceled", variant: "muted" },
};

export default function TransactionsPage() {
  const invCreated = useEvents("InvoiceCreated", { limit: 100 });
  const paid = useEvents("InvoicePaid", { limit: 100 });
  const invCx = useEvents("InvoiceCanceled", { limit: 100 });
  const vouCreated = useEvents("VoucherCreated", { limit: 100 });
  const redeemed = useEvents("VoucherRedeemed", { limit: 100 });
  const vouCx = useEvents("VoucherCanceled", { limit: 100 });

  /** Invoice ids that have reached a terminal state (paid or canceled). */
  const terminatedInvoiceIds = useMemo(() => {
    return new Set([
      ...(paid.data ?? []).map((e) => e.parsed.invoice_id as string),
      ...(invCx.data ?? []).map((e) => e.parsed.invoice_id as string),
    ]);
  }, [paid.data, invCx.data]);

  const feed = useMemo<FeedRow[]>(() => {
    const all = [
      ...rowsFrom("InvoiceCreated", invCreated.data ?? []),
      ...rowsFrom("InvoicePaid", paid.data ?? []),
      ...rowsFrom("InvoiceCanceled", invCx.data ?? []),
      ...rowsFrom("VoucherCreated", vouCreated.data ?? []),
      ...rowsFrom("VoucherRedeemed", redeemed.data ?? []),
      ...rowsFrom("VoucherCanceled", vouCx.data ?? []),
    ];
    all.sort((a, b) => Number(b.timestampMs - a.timestampMs));
    return all;
  }, [invCreated.data, paid.data, invCx.data, vouCreated.data, redeemed.data, vouCx.data]);

  const isLoading =
    invCreated.isLoading ||
    paid.isLoading ||
    invCx.isLoading ||
    vouCreated.isLoading ||
    redeemed.isLoading ||
    vouCx.isLoading;

  return (
    <section>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Transactions</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          On-chain events grouped by lifecycle (open / settled / canceled).
        </p>
      </header>

      {isLoading ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading events…</p>
      ) : feed.length === 0 ? (
        <div className="rounded-lg border border-dashed border-[color:var(--color-border)] p-12 text-center text-sm text-[color:var(--color-muted-foreground)]">
          No transactions yet. Issue an invoice in <strong>Catalogue</strong> to get started.
        </div>
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>{feed.length} events</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="divide-y divide-[color:var(--color-border)]">
              {feed.map((row) =>
                row.name === "InvoiceCreated" ? (
                  <OpenInvoiceRow
                    key={row.digest}
                    invoiceId={row.data.invoice_id as string}
                    timestampMs={row.timestampMs}
                    terminated={terminatedInvoiceIds.has(row.data.invoice_id as string)}
                  />
                ) : (
                  <FeedRowView key={row.digest} row={row} />
                ),
              )}
            </div>
          </CardContent>
        </Card>
      )}
    </section>
  );
}

/**
 * Renders an `InvoiceCreated` row enriched with live data from the Invoice
 * object — but only if the invoice hasn't reached a terminal state yet
 * (paid/canceled invoices are destroyed and `useInvoice` would 404).
 */
function OpenInvoiceRow({
  invoiceId,
  timestampMs,
  terminated,
}: {
  invoiceId: string;
  timestampMs: bigint;
  terminated: boolean;
}) {
  const v = variants[terminated ? "InvoicePaid" : "InvoiceCreated"];
  // Skip the network read when we already know the invoice is gone.
  const invoice = useInvoice(terminated ? null : invoiceId);

  const when = timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "—";

  return (
    <div className="flex items-center justify-between gap-4 py-3">
      <div className="flex items-center gap-3">
        <Badge variant={v.variant}>
          {terminated ? "Invoice closed" : v.label}
        </Badge>
        <div>
          {invoice.data ? (
            <>
              <div className="text-sm font-medium">
                {invoice.data.amount.toString()} units · {invoice.data.loyalty.toString()} LOY
              </div>
              <div className="text-xs text-[color:var(--color-muted-foreground)]">
                {invoice.data.items.length} item
                {invoice.data.items.length === 1 ? "" : "s"} ·{" "}
                {new TextDecoder().decode(new Uint8Array(invoice.data.orderRef))}
              </div>
            </>
          ) : invoice.isLoading ? (
            <div className="text-sm text-[color:var(--color-muted-foreground)]">Loading…</div>
          ) : (
            <div className="text-sm text-[color:var(--color-muted-foreground)] font-mono">
              {shortAddr(invoiceId, 6)}
            </div>
          )}
        </div>
      </div>
      <div className="flex items-center gap-3">
        {!terminated && invoice.data ? <InvoiceQrButton invoiceId={invoiceId} /> : null}
        <div className="text-xs text-[color:var(--color-muted-foreground)]">{when}</div>
      </div>
    </div>
  );
}

/** Renders any feed row that doesn't need enrichment (events with full payload). */
function FeedRowView({ row }: { row: FeedRow }) {
  const v = variants[row.name];
  const when = row.timestampMs ? new Date(Number(row.timestampMs)).toLocaleString() : "—";
  const amount = row.data.amount as string | undefined;
  const loyalty = row.data.loyalty as string | undefined;
  const customer = row.data.customer as string | undefined;
  const orderRefBytes = row.data.order_ref as number[] | undefined;
  const orderRef = orderRefBytes
    ? new TextDecoder().decode(new Uint8Array(orderRefBytes))
    : null;

  return (
    <div className="flex items-center justify-between gap-4 py-3">
      <div className="flex items-center gap-3">
        <Badge variant={v.variant}>{v.label}</Badge>
        <div>
          <div className="text-sm font-medium">
            {amount ? `${amount} units` : "—"}
            {loyalty ? ` · ${loyalty} LOY` : ""}
          </div>
          <div className="text-xs text-[color:var(--color-muted-foreground)]">
            {customer ? shortAddr(customer) : "—"}
            {orderRef ? ` · ${orderRef}` : ""}
          </div>
        </div>
      </div>
      <div className="text-xs text-[color:var(--color-muted-foreground)]">{when}</div>
    </div>
  );
}
