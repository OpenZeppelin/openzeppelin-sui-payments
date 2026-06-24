"use client";

import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { CheckCircle2 } from "lucide-react";

import { QrDisplay } from "@/components/shared/qr-display";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { qk, useInvoiceReceipt } from "@/hooks/queries";
import { deployment } from "@/lib/deployment";
import { STABLECOIN_DECIMALS, formatAmount, shortAddr } from "@/lib/utils";

/** How often we re-check the receipt table while the dialog is open. */
const POLL_MS = 1_000;

/**
 * Shows the invoice QR while the customer hasn't paid yet, then swaps to a
 * "payment received" summary the moment the on-chain receipt appears in
 * `merchant.invoice_receipts`. Polls every POLL_MS while the dialog is open;
 * once a receipt arrives, also invalidates the transactions-page event
 * queries so the feed re-renders if the merchant navigates there next.
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
  // Poll only while the dialog is actually on screen — saves RPC and React work
  // on stale invoices the merchant has long dismissed.
  const receipt = useInvoiceReceipt(open ? invoiceId : null, { pollMs: POLL_MS });

  // When the receipt materializes, invalidate the transactions-feed queries so
  // an "Invoice closed" / "Paid" row shows up the next time the merchant
  // navigates to /merchant/transactions.
  useEffect(() => {
    if (!receipt.data) return;
    void queryClient.invalidateQueries({
      queryKey: qk.events(`${deployment.packageId}::events::InvoicePaid`),
    });
    void queryClient.invalidateQueries({ queryKey: qk.invoice(receipt.data.invoiceId) });
  }, [receipt.data, queryClient]);

  const paid = receipt.data;

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
        ) : (
          <>
            <DialogHeader>
              <DialogTitle>Show this to the customer</DialogTitle>
              <DialogDescription>
                Waiting for payment… this dialog will update automatically when
                the customer settles. Invoice expires per the merchant config.
              </DialogDescription>
            </DialogHeader>
            {invoiceId ? <QrDisplay value={invoiceId} label="Invoice ID" /> : null}
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
