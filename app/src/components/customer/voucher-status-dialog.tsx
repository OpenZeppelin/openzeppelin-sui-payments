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
import { qk, useVoucher, useVoucherReceipt } from "@/hooks/queries";
import { deployment } from "@/lib/deployment";
import { shortAddr } from "@/lib/utils";

/** How often we re-check the receipt + voucher tables while the dialog is open. */
const POLL_MS = 1_000;

/**
 * Customer-side counterpart to `InvoiceStatusDialog` — same three-state model:
 *
 *   - **Open**     — voucher still in `merchant.vouchers`, no receipt yet.
 *                    Renders the QR; this is the initial state.
 *   - **Redeemed** — `Receipt<Redemption>` landed at
 *                    `merchant.voucher_receipts[voucher_id]`. Shows what was
 *                    burned (LOY) + line items + when.
 *   - **Canceled** — voucher gone from `merchant.vouchers` AND no receipt
 *                    arrived (expired and someone called `cancel_voucher`).
 *                    Shows a "Refunded" notice — the LOY went back to the
 *                    customer's PAS Account.
 */
export function VoucherStatusDialog({
  voucherId,
  open,
  onOpenChange,
}: {
  voucherId: string | null;
  open: boolean;
  onOpenChange: (next: boolean) => void;
}) {
  const queryClient = useQueryClient();
  const target = open ? voucherId : null;
  const voucher = useVoucher(target, { pollMs: POLL_MS });
  const receipt = useVoucherReceipt(target, { pollMs: POLL_MS });

  useEffect(() => {
    if (!receipt.data && !(voucher.isSuccess && voucher.data === null)) return;
    if (receipt.data) {
      void queryClient.invalidateQueries({
        queryKey: qk.events(`${deployment.packageId}::events::VoucherRedeemed`),
      });
    } else {
      void queryClient.invalidateQueries({
        queryKey: qk.events(`${deployment.packageId}::events::VoucherCanceled`),
      });
    }
    if (voucherId) {
      void queryClient.invalidateQueries({ queryKey: qk.voucher(voucherId) });
    }
    void queryClient.invalidateQueries({ queryKey: ["my-open-vouchers"] });
    // Cancellation refunds LOY into the customer's PAS account — invalidate
    // any cached balance for it.
    void queryClient.invalidateQueries({ queryKey: ["balances"] });
  }, [receipt.data, voucher.isSuccess, voucher.data, voucherId, queryClient]);

  const redeemed = receipt.data;
  const canceled =
    !redeemed &&
    voucher.isSuccess &&
    voucher.data === null &&
    receipt.isSuccess &&
    receipt.data === null;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        {redeemed ? (
          <>
            <DialogHeader>
              <DialogTitle className="flex items-center gap-2">
                <CheckCircle2 className="h-5 w-5 text-[color:var(--color-accent)]" />
                Voucher redeemed
              </DialogTitle>
              <DialogDescription>
                The merchant settled. Enjoy your reward.
              </DialogDescription>
            </DialogHeader>
            <div className="grid gap-3 text-sm">
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  LOY burned
                </div>
                <div className="mt-1 text-2xl font-semibold">
                  {redeemed.amount.toString()} LOY
                </div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Items
                </div>
                <ul className="mt-1 list-disc pl-5">
                  {redeemed.items.map((it, i) => (
                    <li key={i}>
                      {it.quantity.toString()}× variant{" "}
                      {shortAddr(it.variantId, 4)} · {it.price.toString()} LOY
                    </li>
                  ))}
                </ul>
              </div>
              <div className="text-xs text-[color:var(--color-muted-foreground)]">
                {new Date(Number(redeemed.timestampMs)).toLocaleString()}
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
                Voucher canceled
              </DialogTitle>
              <DialogDescription>
                The voucher expired before the merchant redeemed it. The locked
                LOY has been refunded to your PAS account.
              </DialogDescription>
            </DialogHeader>
            <div className="flex justify-end">
              <Button onClick={() => onOpenChange(false)}>Done</Button>
            </div>
          </>
        ) : (
          <>
            <DialogHeader>
              <DialogTitle>Show this to the merchant</DialogTitle>
              <DialogDescription>
                Waiting for redemption… this dialog will update automatically
                when the merchant scans and burns the LOY.
              </DialogDescription>
            </DialogHeader>
            {voucherId ? <QrDisplay value={voucherId} label="Voucher ID" /> : null}
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
