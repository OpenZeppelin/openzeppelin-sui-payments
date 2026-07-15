"use client";

import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, XCircle } from "lucide-react";

import { QrDisplay } from "@/components/shared/qr-display";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { qk, useInvoice, useInvoiceReceipt } from "@/hooks/queries";
import { useVariantLookup } from "@/hooks/use-variant-lookup";
import { deployment } from "@/lib/deployment";
import { encodeInvoiceQr } from "@/lib/qr";
import { STABLECOIN_DECIMALS, formatAmount, shortAddr } from "@/lib/utils";

/** How often we re-check the receipt + invoice tables while the dialog is open. */
const POLL_MS = 1_000;

/**
 * Three-state dialog for an open invoice:
 *
 *   - **Open**          — invoice still in `merchant.invoices` and no receipt yet.
 *                         Renders the QR; this is the initial state.
 *   - **Paid**          — a `Receipt<Payment>` arrived at
 *                         `merchant.invoice_receipts[invoice_id]`. Renders the
 *                         payment summary (amount, LOY minted, customer).
 *   - **Canceled**      — invoice is gone from `merchant.invoices` AND no
 *                         receipt landed (someone called `cancel_expired_invoice` after
 *                         expiry). Renders a "Canceled" notice.
 *
 * Both polls run every POLL_MS while the dialog is open. We require both
 * queries to have completed before declaring "canceled" so that a transient
 * mid-redeem state (object gone, receipt not yet visible) doesn't flicker
 * through a false canceled view.
 */
export function InvoiceStatusDialog({
  invoiceId,
  open,
  onOpenChange,
}: {
  invoiceId: string | null;
  open: boolean;
  onOpenChange: (next: boolean) => void;
}) {
  const queryClient = useQueryClient();
  const target = open ? invoiceId : null;
  const invoice = useInvoice(target, { pollMs: POLL_MS });
  const receipt = useInvoiceReceipt(target, { pollMs: POLL_MS });
  const variantLookup = useVariantLookup();

  // Cross-page consistency: when terminal state is reached, refresh the
  // transactions feed + per-invoice caches.
  useEffect(() => {
    if (!receipt.data && !(invoice.isSuccess && invoice.data === null)) return;
    if (receipt.data) {
      void queryClient.invalidateQueries({
        queryKey: qk.events(`${deployment.packageId}::events::InvoicePaid`),
      });
      void queryClient.invalidateQueries({ queryKey: qk.invoice(receipt.data.invoiceId) });
    } else {
      void queryClient.invalidateQueries({
        queryKey: qk.events(`${deployment.packageId}::events::InvoiceCanceled`),
      });
      if (invoiceId) {
        void queryClient.invalidateQueries({ queryKey: qk.invoice(invoiceId) });
      }
    }
  }, [receipt.data, invoice.isSuccess, invoice.data, invoiceId, queryClient]);

  const paid = receipt.data;
  // Only declare canceled when BOTH queries have returned a confirmed-empty
  // answer. This avoids the brief inconsistent window during settlement where
  // the invoice was removed but the receipt hasn't shown up yet.
  const canceled =
    !paid &&
    invoice.isSuccess &&
    invoice.data === null &&
    receipt.isSuccess &&
    receipt.data === null;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        {paid ? (
          <>
            <DialogHeader>
              <DialogTitle className="flex items-center gap-2">
                <CheckCircle2 className="h-5 w-5 text-[color:var(--color-accent)]" />
                Payment received
              </DialogTitle>
              <DialogDescription>
                Settled on chain. Hand over the goods.
              </DialogDescription>
            </DialogHeader>
            <div className="grid gap-3 text-sm">
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                    Amount
                  </div>
                  <div className="mt-1 text-2xl font-semibold">
                    {formatAmount(paid.amount, STABLECOIN_DECIMALS)} USD
                  </div>
                </div>
                <div>
                  <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                    Loyalty minted
                  </div>
                  <div className="mt-1 text-2xl font-semibold">
                    {paid.loyalty.toString()} LOY
                  </div>
                </div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Items
                </div>
                <ul className="mt-1 list-disc pl-5">
                  {paid.items.map((it, i) => {
                    const label = variantLookup.get(it.variantId) ?? shortAddr(it.variantId, 6);
                    return (
                      <li key={i}>
                        {it.quantity.toString()}× {label} ·{" "}
                        {formatAmount(it.price, STABLECOIN_DECIMALS)} USD
                      </li>
                    );
                  })}
                </ul>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Customer
                </div>
                <div className="mt-1 font-mono">{shortAddr(paid.customer, 8)}</div>
              </div>
              {paid.orderRef.length > 0 ? (
                <div>
                  <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                    Order ref
                  </div>
                  <div className="mt-1">
                    {new TextDecoder().decode(new Uint8Array(paid.orderRef))}
                  </div>
                </div>
              ) : null}
              <div className="text-xs text-[color:var(--color-muted-foreground)]">
                {new Date(Number(paid.timestampMs)).toLocaleString()}
              </div>
            </div>
            <div className="flex justify-end">
              <Button onClick={() => onOpenChange(false)}>Done</Button>
            </div>
          </>
        ) : canceled ? (
          <>
            <DialogHeader>
              <DialogTitle className="flex items-center gap-2">
                <XCircle className="h-5 w-5 text-[color:var(--color-destructive)]" />
                Invoice canceled
              </DialogTitle>
              <DialogDescription>
                The invoice was canceled before the customer settled — likely
                expired and cleaned up. No payment was received.
              </DialogDescription>
            </DialogHeader>
            <div className="flex justify-end">
              <Button onClick={() => onOpenChange(false)}>Done</Button>
            </div>
          </>
        ) : (
          <>
            <DialogHeader>
              <DialogTitle>Show this to the customer</DialogTitle>
              <DialogDescription>
                Waiting for payment… this dialog will update automatically when
                the customer settles. Invoice expires per the merchant config.
              </DialogDescription>
            </DialogHeader>
            {invoiceId ? (
              <QrDisplay value={encodeInvoiceQr(invoiceId)} label="Invoice code" />
            ) : null}
            <div className="flex justify-end">
              <Button variant="ghost" onClick={() => onOpenChange(false)}>
                Done
              </Button>
            </div>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
