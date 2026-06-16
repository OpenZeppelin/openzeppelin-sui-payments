"use client";

import { useState } from "react";
import { QrCode } from "lucide-react";

import { QrDisplay } from "@/components/shared/qr-display";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

/**
 * Compact "QR" button that opens a dialog containing the invoice QR code.
 * Reused from the Transactions page so the merchant can re-show a QR if the
 * customer couldn't scan it the first time around.
 */
export function InvoiceQrButton({ invoiceId }: { invoiceId: string }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
        <QrCode className="h-4 w-4" />
        Show QR
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Invoice QR code</DialogTitle>
            <DialogDescription>
              Customer scans to pay. Copy the id below if scanning fails.
            </DialogDescription>
          </DialogHeader>
          <QrDisplay value={invoiceId} label="Invoice ID" />
          <div className="flex justify-end">
            <Button variant="ghost" onClick={() => setOpen(false)}>
              Done
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
