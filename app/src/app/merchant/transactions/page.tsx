"use client";

import { useEffect, useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Trash2 } from "lucide-react";
import { toast } from "sonner";

import { InvoiceQrButton } from "@/components/merchant/invoice-qr-button";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import {
  qk,
  useEvents,
  useInvoice,
  useInvoiceReceipt,
  useListings,
  useStoredReceipts,
  useVoucher,
  useVoucherReceipt,
} from "@/hooks/queries";
import { usePasAccount } from "@/hooks/use-pas-account";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { deployment } from "@/lib/deployment";
import { buildCancelExpiredInvoice, buildPruneInvoiceReceipts } from "@/lib/move/payment";
import { buildCancelExpiredVoucher, buildPruneVoucherReceipts } from "@/lib/move/redemption";
import { STABLECOIN_DECIMALS, formatAmount, formatItems, shortAddr } from "@/lib/utils";

const PRUNE_BATCH_SIZE = 50;
/** Refresh cadence for events + receipt counts while this page is open. */
const POLL_MS = 3_000;
/** Tick cadence for re-evaluating "Expired" badges from the wall clock. */
const CLOCK_TICK_MS = 5_000;

/**
 * Returns a value that changes every `intervalMs` so any component using it
 * re-renders on a clock-driven cadence. Used to flip "Open" rows to "Expired"
 * the moment `expiresAtMs` passes — pure time-based transitions don't fire
 * events, so polling alone can't catch them.
 */
function useClockTick(intervalMs: number) {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), intervalMs);
    return () => clearInterval(t);
  }, [intervalMs]);
  return tick;
}

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
  // Poll the event queries every POLL_MS so new payments / redemptions /
  // cancellations push the feed without manual refresh.
  const invCreated = useEvents("InvoiceCreated", { limit: 100, pollMs: POLL_MS });
  const paid = useEvents("InvoicePaid", { limit: 100, pollMs: POLL_MS });
  const invCx = useEvents("InvoiceCanceled", { limit: 100, pollMs: POLL_MS });
  const vouCreated = useEvents("VoucherCreated", { limit: 100, pollMs: POLL_MS });
  const redeemed = useEvents("VoucherRedeemed", { limit: 100, pollMs: POLL_MS });
  const vouCx = useEvents("VoucherCanceled", { limit: 100, pollMs: POLL_MS });

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

  // Business summary — computed off the InvoicePaid / VoucherRedeemed streams.
  // Revenue is a bigint sum in stablecoin base units; avg-order divides in the
  // same base so precision is preserved through `formatAmount`.
  const { revenue, payments, avgOrder, redemptions } = useMemo(() => {
    let revenueSum = 0n;
    for (const e of paid.data ?? []) {
      revenueSum += BigInt((e.parsed.amount as string | number | undefined) ?? 0);
    }
    const paymentCount = paid.data?.length ?? 0;
    const avg = paymentCount > 0 ? revenueSum / BigInt(paymentCount) : 0n;
    return {
      revenue: revenueSum,
      payments: paymentCount,
      avgOrder: avg,
      redemptions: redeemed.data?.length ?? 0,
    };
  }, [paid.data, redeemed.data]);

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
            <div className="grid grid-cols-2 gap-6 md:grid-cols-4">
              <Stat label="Revenue" value={`${formatAmount(revenue, STABLECOIN_DECIMALS)} USD`} />
              <Stat
                label="Avg. order"
                value={payments > 0 ? `${formatAmount(avgOrder, STABLECOIN_DECIMALS)} USD` : "—"}
              />
              <Stat label="Payments" value={payments.toString()} />
              <Stat label="Redemptions" value={redemptions.toString()} />
            </div>
          </CardHeader>
          <CardContent>
            <div className="divide-y divide-[color:var(--color-border)]">
              {feed.map((row) => {
                if (row.name === "InvoiceCreated") {
                  return (
                    <OpenInvoiceRow
                      key={row.digest}
                      invoiceId={row.data.invoice_id as string}
                      timestampMs={row.timestampMs}
                      terminated={terminatedInvoiceIds.has(row.data.invoice_id as string)}
                    />
                  );
                }
                if (row.name === "VoucherCreated") {
                  return (
                    <OpenVoucherRow
                      key={row.digest}
                      voucherId={row.data.voucher_id as string}
                      timestampMs={row.timestampMs}
                      terminated={terminatedVoucherIds.has(row.data.voucher_id as string)}
                    />
                  );
                }
                if (row.name === "InvoicePaid") {
                  return (
                    <PaidRow
                      key={row.digest}
                      invoiceId={row.data.invoice_id as string}
                      row={row}
                    />
                  );
                }
                if (row.name === "VoucherRedeemed") {
                  return (
                    <RedeemedRow
                      key={row.digest}
                      voucherId={row.data.voucher_id as string}
                      row={row}
                    />
                  );
                }
                // Canceled events: on-chain invoice/voucher removed, no receipt
                // created — items are unrecoverable, render summary only.
                return <FeedRowView key={row.digest} row={row} />;
              })}
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
  const { data: listings = [] } = useListings();
  // Re-render on the clock tick so the "Expired" badge flips on time even
  // when no chain event has fired (TTL elapsed but nobody canceled yet).
  useClockTick(CLOCK_TICK_MS);

  const now = BigInt(Date.now());
  const expired = Boolean(invoice.data && invoice.data.expiresAtMs <= now);

  const status = terminated ? "closed" : expired ? "expired" : "open";
  const badge: { label: string; variant: "outline" | "destructive" | "accent" } =
    status === "closed"
      ? { label: "Invoice closed", variant: "accent" }
      : status === "expired"
      ? { label: "Expired", variant: "destructive" }
      : { label: "Invoice open", variant: "outline" };

  // Merchant signs the cancel themselves — permissionless after expiry, so
  // any signer works. Sponsored (localnet gas station on localnet; Enoki with
  // an Enoki wallet on testnet; wallet-paid otherwise).
  const remove = useSponsoredMutation<{ invoiceId: string }>(
    (tx, args) => buildCancelExpiredInvoice(tx, args.invoiceId),
    {
      invalidate: [
        qk.events(`${deployment.packageId}::events::InvoiceCanceled`),
        qk.invoice(invoiceId),
      ],
      successMessage: "Expired invoice removed",
    },
  );

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
                {formatItems(invoice.data.items, listings)} ·{" "}
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
            onClick={() => remove.mutate({ invoiceId })}
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
 * on `merchant.vouchers`. Mirrors `OpenInvoiceRow` but with `cancel_expired_voucher` (which
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
  const { data: listings = [] } = useListings();
  useClockTick(CLOCK_TICK_MS);

  const now = BigInt(Date.now());
  const expired = Boolean(voucher.data && voucher.data.expiresAtMs <= now);

  const status = terminated ? "closed" : expired ? "expired" : "open";
  const badge: { label: string; variant: "outline" | "destructive" | "accent" } =
    status === "closed"
      ? { label: "Voucher closed", variant: "accent" }
      : status === "expired"
      ? { label: "Expired", variant: "destructive" }
      : { label: "Voucher open", variant: "outline" };

  // Merchant signs cancel_expired_voucher themselves (permissionless after expiry).
  // Needs the voucher owner's PAS account id to refund unlocked LOY — derived
  // from `voucher.customer` via the standard `usePasAccount` lookup.
  const customerPas = usePasAccount(voucher.data?.customer ?? null);
  const remove = useSponsoredMutation<{
    voucherId: string;
    customerLoyaltyAccountId: string;
  }>(
    (tx, args) =>
      buildCancelExpiredVoucher(tx, {
        voucherId: args.voucherId,
        customerLoyaltyAccountId: args.customerLoyaltyAccountId,
      }),
    {
      invalidate: [
        qk.events(`${deployment.packageId}::events::VoucherCanceled`),
        qk.voucher(voucherId),
      ],
      successMessage: "Expired voucher canceled — LOY refunded to customer",
    },
  );

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
                {formatItems(voucher.data.items, listings)} ·{" "}
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
            onClick={() =>
              remove.mutate({
                voucherId,
                customerLoyaltyAccountId: customerPas.data!,
              })
            }
            disabled={remove.isPending || !customerPas.data}
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

/** Compact KPI tile — uppercase muted label + large value below. */
function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
        {label}
      </div>
      <div className="mt-1 text-2xl font-semibold">{value}</div>
    </div>
  );
}

/**
 * `InvoicePaid` row enriched with items from the stored payment receipt.
 * Receipts live on `merchant.invoice_receipts` keyed by the settled invoice id.
 * Items are lost when the receipt is pruned — falls back to the summary
 * layout while the receipt query is loading or after prune.
 */
function PaidRow({ invoiceId, row }: { invoiceId: string; row: FeedRow }) {
  const receipt = useInvoiceReceipt(invoiceId);
  const { data: listings = [] } = useListings();
  return (
    <FeedRowView row={row} itemsLabel={receipt.data ? formatItems(receipt.data.items, listings) : null} />
  );
}

/** Mirror of `PaidRow` for `VoucherRedeemed`. */
function RedeemedRow({ voucherId, row }: { voucherId: string; row: FeedRow }) {
  const receipt = useVoucherReceipt(voucherId);
  const { data: listings = [] } = useListings();
  return (
    <FeedRowView row={row} itemsLabel={receipt.data ? formatItems(receipt.data.items, listings) : null} />
  );
}

/** Renders any feed row that doesn't need enrichment (events with full payload). */
function FeedRowView({ row, itemsLabel }: { row: FeedRow; itemsLabel?: string | null }) {
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
            {itemsLabel ? `${itemsLabel} · ` : ""}
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
  const stored = useStoredReceipts({ pollMs: POLL_MS });
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
