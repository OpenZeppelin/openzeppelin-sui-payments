"use client";

import { useState } from "react";
import { QrCode } from "lucide-react";

import { InvoiceStatusDialog } from "@/components/merchant/invoice-status-dialog";
import { Button } from "@/components/ui/button";

/**
 * Compact "QR" button used in the merchant transactions feed. Opens the same
 * `InvoiceStatusDialog` the catalogue uses, so re-shown QRs also auto-update
 * if the customer settles while the dialog is open.
 */
export function InvoiceQrButton({ invoiceId }: { invoiceId: string }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
        <QrCode className="h-4 w-4" />
        Show QR
      </Button>
      <InvoiceStatusDialog
        invoiceId={open ? invoiceId : null}
        open={open}
        onOpenChange={setOpen}
      />
    </>
  );
}
