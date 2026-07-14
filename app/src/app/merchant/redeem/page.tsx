"use client";

import { useMemo, useState } from "react";
import { CheckCircle2 } from "lucide-react";
import { toast } from "sonner";

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
import { useSuiClockMs } from "@/hooks/use-sui-clock";
import { useVariantLookup } from "@/hooks/use-variant-lookup";
import { buildRedeem } from "@/lib/move/redemption";
import { deployment } from "@/lib/deployment";
import { blake2b256, bytesEqual } from "@/lib/preimage";
import { decodeVoucherQr } from "@/lib/qr";
import { shortAddr } from "@/lib/utils";

interface ScannedVoucher {
  voucherId: string;
  preimage: Uint8Array;
}

export default function RedeemPage() {
  const [scanned, setScanned] = useState<ScannedVoucher | null>(null);
  const [done, setDone] = useState<{ amount: bigint; customer: string } | null>(null);
  const voucher = useVoucher(scanned?.voucherId ?? null);

  const variantLookup = useVariantLookup();

  const redeem = useSponsoredMutation<ScannedVoucher>(
    (tx, args) => {
      buildRedeem(tx, args.voucherId, args.preimage);
    },
    {
      invalidate: [qk.events(`${deployment.packageId}::events::VoucherRedeemed`)],
      successMessage: null,
    },
  );

  // Client-side sanity check: does the scanned preimage hash to the voucher's
  // committed `redeem_hash`? The chain enforces this regardless, but a local
  // pre-check saves a failed gas spend on a wrong scan and gives the cashier
  // a clear ✓/⚠ badge before clicking Redeem.
  const preimageMatch = useMemo(() => {
    if (!scanned || !voucher.data) return null;
    return bytesEqual(blake2b256(scanned.preimage), voucher.data.redeemHash);
  }, [scanned, voucher.data]);

  async function handleRedeem() {
    if (!voucher.data || !scanned) return;
    // `mutateAsync` re-throws on failure so we can gate the post-success
    // state updates below. Local try/catch silences the unhandled-rejection
    // that would otherwise reach the dev overlay — the user-facing toast is
    // already emitted by `useSponsoredMutation`'s onError handler.
    try {
      await redeem.mutateAsync(scanned);
    } catch {
      return;
    }
    setDone({ amount: voucher.data.amount, customer: voucher.data.customer });
    setScanned(null);
  }

  function handleScan(raw: string) {
    const parsed = decodeVoucherQr(raw);
    if (!parsed) {
      toast.error("Not a voucher QR. Expecting a 64-byte base32 payload.");
      return;
    }
    setScanned(parsed);
  }

  // Compare against the on-chain Clock at 0x6 — wallclock can lag the localnet
  // Clock by many minutes, so `Date.now()` mismarks fresh vouchers as expired.
  const chainNow = useSuiClockMs().data;
  const expired = Boolean(voucher.data && chainNow && voucher.data.expiresAtMs <= chainNow);

  return (
    <section>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Redeem</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Scan or paste the customer&apos;s voucher QR. Confirm to burn the
          locked LOYALTY and hand over the goods.
        </p>
      </header>

      {!scanned ? (
        <Card>
          <CardHeader>
            <CardDescription>Voucher input</CardDescription>
          </CardHeader>
          <CardContent>
            <QrScanner
              onResult={handleScan}
              placeholder="Paste voucher code"
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
            <Button variant="ghost" onClick={() => setScanned(null)}>
              Try again
            </Button>
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardHeader>
            <div className="flex items-center justify-between">
              <CardTitle>Voucher</CardTitle>
              <div className="flex items-center gap-2">
                {preimageMatch === false ? (
                  <Badge variant="destructive">Wrong preimage</Badge>
                ) : preimageMatch ? (
                  <Badge variant="accent">Preimage verified</Badge>
                ) : null}
                {expired ? (
                  <Badge variant="destructive">Expired</Badge>
                ) : (
                  <Badge variant="accent">Active</Badge>
                )}
              </div>
            </div>
            <CardDescription>{shortAddr(scanned.voucherId, 8)}</CardDescription>
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
                {voucher.data.items.map((it, i) => {
                  const label = variantLookup.get(it.variantId) ?? shortAddr(it.variantId, 6);
                  return (
                    <li key={i}>
                      {it.quantity.toString()}× {label} · {it.price.toString()} LOY
                    </li>
                  );
                })}
              </ul>
            </div>
            {preimageMatch === false ? (
              <p className="text-sm text-[color:var(--color-destructive)]">
                The scanned QR&apos;s preimage doesn&apos;t hash to this
                voucher&apos;s commitment. Ask the customer to re-show the QR;
                submitting now would abort with <code>EWrongPreimage</code>.
              </p>
            ) : null}
            <div className="mt-2 flex justify-end gap-2">
              <Button variant="ghost" onClick={() => setScanned(null)}>
                Cancel
              </Button>
              <Button
                onClick={handleRedeem}
                disabled={expired || redeem.isPending || preimageMatch === false}
              >
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
