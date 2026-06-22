"use client";

import { useState } from "react";
import { CheckCircle2 } from "lucide-react";

import { QrScanner } from "@/components/shared/qr-scanner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { qk, useVoucher } from "@/hooks/queries";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { buildRedeem } from "@/lib/move/redemption";
import { deployment } from "@/lib/deployment";
import { shortAddr } from "@/lib/utils";

export default function RedeemPage() {
  const [voucherId, setVoucherId] = useState<string | null>(null);
  const [done, setDone] = useState<{ amount: bigint; customer: string } | null>(null);
  const voucher = useVoucher(voucherId);

  const redeem = useSponsoredMutation<{ voucherId: string }>(
    (tx, args) => {
      buildRedeem(tx, args.voucherId);
    },
    {
      invalidate: [
        qk.events(`${deployment.packageId}::events::VoucherRedeemed`),
      ],
      successMessage: null,
    },
  );

  async function handleRedeem() {
    if (!voucher.data || !voucherId) return;
    await redeem.mutateAsync({ voucherId });
    setDone({ amount: voucher.data.amount, customer: voucher.data.customer });
    setVoucherId(null);
  }

  const now = Date.now();
  const expired = voucher.data ? voucher.data.expiresAtMs <= BigInt(now) : false;

  return (
    <section>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Redeem</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Scan or paste a voucher ID. Confirm to burn the locked LOYALTY and hand over the goods.
        </p>
      </header>

      {!voucherId ? (
        <Card>
          <CardHeader>
            <CardDescription>Voucher input</CardDescription>
          </CardHeader>
          <CardContent>
            <QrScanner
              onResult={(v) => setVoucherId(v)}
              placeholder="Paste voucher ID (0x…)"
            />
          </CardContent>
        </Card>
      ) : voucher.isLoading ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading voucher…</p>
      ) : voucher.isError || !voucher.data ? (
        <Card>
          <CardContent className="flex flex-col items-start gap-3 py-6">
            <p className="text-sm text-[color:var(--color-destructive)]">
              Could not load voucher: {voucher.error?.message ?? "not found"}
            </p>
            <Button variant="ghost" onClick={() => setVoucherId(null)}>
              Try again
            </Button>
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardHeader>
            <div className="flex items-center justify-between">
              <CardTitle>Voucher</CardTitle>
              {expired ? (
                <Badge variant="destructive">Expired</Badge>
              ) : (
                <Badge variant="accent">Active</Badge>
              )}
            </div>
            <CardDescription>{shortAddr(voucherId, 8)}</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-4">
            <div className="grid grid-cols-2 gap-4">
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Customer
                </div>
                <div className="mt-1 font-mono text-sm">{shortAddr(voucher.data.customer, 6)}</div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Locked LOYALTY
                </div>
                <div className="mt-1 text-lg font-semibold">{voucher.data.amount.toString()}</div>
              </div>
            </div>
            <div>
              <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                Items
              </div>
              <ul className="mt-1 list-disc pl-5 text-sm">
                {voucher.data.items.map((it, i) => (
                  <li key={i}>
                    {it.quantity.toString()}× variant {shortAddr(it.variantId, 4)} ·{" "}
                    {it.price.toString()} LOY
                  </li>
                ))}
              </ul>
            </div>
            <div className="mt-2 flex justify-end gap-2">
              <Button variant="ghost" onClick={() => setVoucherId(null)}>
                Cancel
              </Button>
              <Button onClick={handleRedeem} disabled={expired || redeem.isPending}>
                {redeem.isPending ? "Redeeming…" : "Redeem"}
              </Button>
            </div>
          </CardContent>
        </Card>
      )}

      <Dialog open={Boolean(done)} onOpenChange={(o) => !o && setDone(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <CheckCircle2 className="h-5 w-5 text-[color:var(--color-accent)]" />
              Voucher redeemed
            </DialogTitle>
            <DialogDescription>
              {done ? (
                <>
                  Burned <strong>{done.amount.toString()} LOY</strong> from{" "}
                  <span className="font-mono">{shortAddr(done.customer)}</span>. Hand over the
                  goods.
                </>
              ) : null}
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end">
            <Button onClick={() => setDone(null)}>Done</Button>
          </div>
        </DialogContent>
      </Dialog>
    </section>
  );
}
