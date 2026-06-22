"use client";

import { useMemo } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Trash2 } from "lucide-react";
import { toast } from "sonner";

import { InvoiceQrButton } from "@/components/merchant/invoice-qr-button";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { qk, useEvents, useInvoice, useStoredReceipts, useVoucher } from "@/hooks/queries";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { deployment } from "@/lib/deployment";
import { buildPruneInvoiceReceipts } from "@/lib/move/payment";
import { buildPruneVoucherReceipts } from "@/lib/move/redemption";
import { STABLECOIN_DECIMALS, formatAmount, shortAddr } from "@/lib/utils";

const PRUNE_BATCH_SIZE = 50;

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

  /** Voucher ids that have reached a terminal state (redeemed or canceled). */
  const terminatedVoucherIds = useMemo(() => {
    return new Set([
      ...(redeemed.data ?? []).map((e) => e.parsed.voucher_id as string),
      ...(vouCx.data ?? []).map((e) => e.parsed.voucher_id as string),
    ]);
  }, [redeemed.data, vouCx.data]);

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
      <header className="mb-6 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Transactions</h1>
          <p className="text-sm text-[color:var(--color-muted-foreground)]">
            On-chain events grouped by lifecycle (open / settled / canceled).
          </p>
        </div>
        <PruneReceiptsButton />
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
                ) : row.name === "VoucherCreated" ? (
                  <OpenVoucherRow
                    key={row.digest}
                    voucherId={row.data.voucher_id as string}
                    timestampMs={row.timestampMs}
                    terminated={terminatedVoucherIds.has(row.data.voucher_id as string)}
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
 * stored on `merchant.invoices` — but only if the invoice hasn't reached a
 * terminal state yet (paid/canceled invoices are removed from the table, so
 * `useInvoice`'s dynamic-field lookup would return null).
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
  const queryClient = useQueryClient();
  // Skip the network read when we already know the invoice is gone.
  const invoice = useInvoice(terminated ? null : invoiceId);

  const now = BigInt(Date.now());
  const expired = Boolean(invoice.data && invoice.data.expiresAtMs <= now);

  const status = terminated ? "closed" : expired ? "expired" : "open";
  const badge: { label: string; variant: "outline" | "destructive" | "accent" } =
    status === "closed"
      ? { label: "Invoice closed", variant: "accent" }
      : status === "expired"
      ? { label: "Expired", variant: "destructive" }
      : { label: "Invoice open", variant: "outline" };

  const remove = useMutation({
    mutationFn: async (id: string) => {
      const resp = await fetch("/api/cancel-invoice", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ invoiceId: id }),
      });
      if (!resp.ok) {
        const err = (await resp.json().catch(() => null)) as { error?: string } | null;
        throw new Error(err?.error ?? `remove failed (${resp.status})`);
      }
      return (await resp.json()) as { digest: string };
    },
    onSuccess: async () => {
      toast.success("Expired invoice removed");
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: qk.events(`${deployment.packageId}::events::InvoiceCanceled`),
        }),
        queryClient.invalidateQueries({ queryKey: qk.invoice(invoiceId) }),
      ]);
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Remove failed");
    },
  });

  const when = timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "—";

  return (
    <div className="flex items-center justify-between gap-4 py-3">
      <div className="flex items-center gap-3">
        <Badge variant={badge.variant}>{badge.label}</Badge>
        <div>
          {invoice.data ? (
            <>
              <div className="text-sm font-medium">
                {formatAmount(invoice.data.amount, STABLECOIN_DECIMALS)} USD ·{" "}
                {invoice.data.loyalty.toString()} LOY
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
        {status === "open" ? <InvoiceQrButton invoiceId={invoiceId} /> : null}
        {status === "expired" ? (
          <Button
            size="sm"
            variant="outline"
            onClick={() => remove.mutate(invoiceId)}
            disabled={remove.isPending}
          >
            <Trash2 className="h-4 w-4" />
            {remove.isPending ? "Removing…" : "Remove expired"}
          </Button>
        ) : null}
        <div className="text-xs text-[color:var(--color-muted-foreground)]">{when}</div>
      </div>
    </div>
  );
}

/**
 * Renders a `VoucherCreated` row enriched with live data from the Voucher stored
 * on `merchant.vouchers`. Mirrors `OpenInvoiceRow` but with `cancel_voucher` (which
 * needs the customer's PAS account — the server route resolves that from the
 * voucher's `customer` field).
 */
function OpenVoucherRow({
  voucherId,
  timestampMs,
  terminated,
}: {
  voucherId: string;
  timestampMs: bigint;
  terminated: boolean;
}) {
  const queryClient = useQueryClient();
  const voucher = useVoucher(terminated ? null : voucherId);

  const now = BigInt(Date.now());
  const expired = Boolean(voucher.data && voucher.data.expiresAtMs <= now);

  const status = terminated ? "closed" : expired ? "expired" : "open";
  const badge: { label: string; variant: "outline" | "destructive" | "accent" } =
    status === "closed"
      ? { label: "Voucher closed", variant: "accent" }
      : status === "expired"
      ? { label: "Expired", variant: "destructive" }
      : { label: "Voucher open", variant: "outline" };

  const remove = useMutation({
    mutationFn: async (id: string) => {
      const resp = await fetch("/api/cancel-voucher", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ voucherId: id }),
      });
      if (!resp.ok) {
        const err = (await resp.json().catch(() => null)) as { error?: string } | null;
        throw new Error(err?.error ?? `remove failed (${resp.status})`);
      }
      return (await resp.json()) as { digest: string };
    },
    onSuccess: async () => {
      toast.success("Expired voucher canceled — LOY refunded to customer");
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: qk.events(`${deployment.packageId}::events::VoucherCanceled`),
        }),
        queryClient.invalidateQueries({ queryKey: qk.voucher(voucherId) }),
      ]);
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Remove failed");
    },
  });

  const when = timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "—";

  return (
    <div className="flex items-center justify-between gap-4 py-3">
      <div className="flex items-center gap-3">
        <Badge variant={badge.variant}>{badge.label}</Badge>
        <div>
          {voucher.data ? (
            <>
              <div className="text-sm font-medium">
                {voucher.data.amount.toString()} LOY locked
              </div>
              <div className="text-xs text-[color:var(--color-muted-foreground)]">
                {voucher.data.items.length} item
                {voucher.data.items.length === 1 ? "" : "s"} ·{" "}
                <span className="font-mono">{shortAddr(voucher.data.customer, 6)}</span>
              </div>
            </>
          ) : voucher.isLoading ? (
            <div className="text-sm text-[color:var(--color-muted-foreground)]">Loading…</div>
          ) : (
            <div className="text-sm text-[color:var(--color-muted-foreground)] font-mono">
              {shortAddr(voucherId, 6)}
            </div>
          )}
        </div>
      </div>
      <div className="flex items-center gap-3">
        {status === "expired" ? (
          <Button
            size="sm"
            variant="outline"
            onClick={() => remove.mutate(voucherId)}
            disabled={remove.isPending}
          >
            <Trash2 className="h-4 w-4" />
            {remove.isPending ? "Removing…" : "Remove expired"}
          </Button>
        ) : null}
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
  // `amount` is stablecoin for invoice events, LOY for voucher events.
  const isStable = row.name.startsWith("Invoice");
  const amountLabel = amount
    ? isStable
      ? `${formatAmount(BigInt(amount), STABLECOIN_DECIMALS)} USD`
      : `${amount} LOY`
    : "—";

  return (
    <div className="flex items-center justify-between gap-4 py-3">
      <div className="flex items-center gap-3">
        <Badge variant={v.variant}>{v.label}</Badge>
        <div>
          <div className="text-sm font-medium">
            {amountLabel}
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

/**
 * Reads receipt-table sizes from chain, shows a "Prune N receipts" button when
 * there's anything to clean up. One click prunes up to PRUNE_BATCH_SIZE of each
 * kind in a single PTB — for larger backlogs the merchant clicks again.
 */
function PruneReceiptsButton() {
  const stored = useStoredReceipts();
  const queryClient = useQueryClient();

  const prune = useSponsoredMutation<{ invoiceIds: string[]; voucherIds: string[] }>(
    (tx, args) => {
      if (args.invoiceIds.length > 0) buildPruneInvoiceReceipts(tx, args.invoiceIds);
      if (args.voucherIds.length > 0) buildPruneVoucherReceipts(tx, args.voucherIds);
    },
    {
      invalidate: [["stored-receipts"]],
      successMessage: "Receipts pruned",
    },
  );

  const invoiceIds = stored.data?.invoice ?? [];
  const voucherIds = stored.data?.voucher ?? [];
  const total = invoiceIds.length + voucherIds.length;
  if (total === 0) return null;

  // Cap each batch so we don't exceed PTB size with a backlog of hundreds.
  const batch = {
    invoiceIds: invoiceIds.slice(0, PRUNE_BATCH_SIZE),
    voucherIds: voucherIds.slice(0, PRUNE_BATCH_SIZE),
  };
  const batchSize = batch.invoiceIds.length + batch.voucherIds.length;
  const hasMore = total > batchSize;

  return (
    <Button
      size="sm"
      variant="outline"
      onClick={() => prune.mutate(batch)}
      disabled={prune.isPending}
      title="Reclaim storage rebate for settled receipts. Canonical record stays in `InvoicePaid`/`VoucherRedeemed` events."
    >
      <Trash2 className="h-4 w-4" />
      {prune.isPending
        ? "Pruning…"
        : hasMore
        ? `Prune ${batchSize} of ${total} receipts`
        : `Prune ${total} receipts`}
    </Button>
  );
}
