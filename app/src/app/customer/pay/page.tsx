"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { toast } from "sonner";

import { QrScanner } from "@/components/shared/qr-scanner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { qk, useInvoice, useListings } from "@/hooks/queries";
import { usePasAccount } from "@/hooks/use-pas-account";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { deployment } from "@/lib/deployment";
import {
  buildAccountNewAuth,
  buildSendBalance,
} from "@/lib/move/pas";
import { buildPay } from "@/lib/move/payment";
import { decodeInvoiceQr } from "@/lib/qr";
import { buildApproveTransfer } from "@/lib/move/stablecoin";
import { STABLECOIN_DECIMALS, formatAmount, shortAddr } from "@/lib/utils";

export default function CustomerPayPage() {
  const router = useRouter();
  const address = useCurrentAccount()?.address ?? null;
  const [invoiceId, setInvoiceId] = useState<string | null>(null);

  const invoice = useInvoice(invoiceId);
  const customerPas = usePasAccount(address);
  const merchantPas = usePasAccount(invoice.data?.payoutAddress ?? null);

  // Build a variantId → "Listing · Variant" lookup once per catalog refresh so
  // each invoice item can be labeled with human-readable names. Falls back to
  // the short variant id when the variant has been removed from the catalog —
  // invoices outlive the catalog.
  const { data: listings = [] } = useListings();
  const variantLookup = useMemo(() => {
    const m = new Map<string, string>();
    for (const l of listings)
      for (const v of l.variants) m.set(v.id, `${l.name} · ${v.name}`);
    return m;
  }, [listings]);

  const pay = useSponsoredMutation<{
    invoiceId: string;
    amount: bigint;
    customerAccountId: string;
    merchantAccountId: string;
  }>(
    (tx, args) => {
      const auth = buildAccountNewAuth(tx);
      const sendReq = buildSendBalance(tx, {
        auth,
        customerAccountId: args.customerAccountId,
        destAccountId: args.merchantAccountId,
        amount: args.amount,
        coinType: deployment.stablecoinType,
      });
      buildApproveTransfer(tx, sendReq);
      buildPay(tx, {
        invoiceId: args.invoiceId,
        sendRequest: sendReq,
        customerLoyaltyAccountId: args.customerAccountId,
      });
    },
    {
      invalidate: [
        qk.events(`${deployment.packageId}::events::InvoicePaid`),
        qk.balances(customerPas.data ?? ""),
      ],
      successMessage: null,
    },
  );

  async function handlePay() {
    if (!invoice.data || !invoiceId || !customerPas.data || !merchantPas.data) return;
    const amount = invoice.data.amount;
    const loyalty = invoice.data.loyalty;
    await pay.mutateAsync({
      invoiceId,
      amount,
      customerAccountId: customerPas.data,
      merchantAccountId: merchantPas.data,
    });
    toast.success(
      `Paid ${formatAmount(amount, STABLECOIN_DECIMALS)} USD · earned ${loyalty.toString()} LOY`,
    );
    router.push("/customer");
  }

  const now = Date.now();
  const expired = invoice.data ? invoice.data.expiresAtMs <= BigInt(now) : false;
  const merchantAccountReady = merchantPas.data !== null && merchantPas.data !== undefined;
  const customerAccountReady = customerPas.data !== null && customerPas.data !== undefined;
  // Self-payment is a structural dead-end: `account::send_balance(from, .., to, ..)`
  // would have `from` and `to` resolve to the same shared object, which Sui's PTB
  // borrow checker rejects (`InvalidReferenceArgument`). Block it with a clear
  // message rather than letting the chain produce a cryptic error.
  const isSelfPayment =
    Boolean(
      address &&
        invoice.data &&
        address.toLowerCase() === invoice.data.payoutAddress.toLowerCase(),
    );

  return (
    <section className="flex flex-col gap-6">
      <header>
        <h1 className="text-2xl font-semibold">Pay</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Scan the merchant&apos;s invoice QR (or paste the ID). Gas is sponsored.
        </p>
      </header>

      {!invoiceId ? (
        <Card>
          <CardHeader>
            <CardDescription>Invoice input</CardDescription>
          </CardHeader>
          <CardContent>
            <QrScanner
              onResult={(v) => {
                const id = decodeInvoiceQr(v);
                if (!id) {
                  toast.error("Not an invoice QR. Expecting a 32-byte base32 payload.");
                  return;
                }
                setInvoiceId(id);
              }}
              placeholder="Paste invoice code"
            />
          </CardContent>
        </Card>
      ) : invoice.isLoading ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading invoice…</p>
      ) : invoice.isError || !invoice.data ? (
        <Card>
          <CardContent className="flex flex-col items-start gap-3 py-6">
            <p className="text-sm text-[color:var(--color-destructive)]">
              Could not load invoice: {invoice.error?.message ?? "not found"}
            </p>
            <Button variant="ghost" onClick={() => setInvoiceId(null)}>
              Try again
            </Button>
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardHeader>
            <div className="flex items-center justify-between">
              <CardTitle>Invoice</CardTitle>
              {expired ? (
                <Badge variant="destructive">Expired</Badge>
              ) : (
                <Badge variant="accent">Active</Badge>
              )}
            </div>
            <CardDescription>{shortAddr(invoiceId, 8)}</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-4">
            <div className="grid grid-cols-2 gap-4">
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Amount
                </div>
                <div className="mt-1 text-2xl font-semibold">
                  {formatAmount(invoice.data.amount, 6)} USD
                </div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Loyalty earned
                </div>
                <div className="mt-1 text-2xl font-semibold">
                  {invoice.data.loyalty.toString()} LOY
                </div>
              </div>
            </div>
            <div>
              <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                Payout address
              </div>
              <div className="mt-1 font-mono text-sm">{shortAddr(invoice.data.payoutAddress, 8)}</div>
            </div>
            <div>
              <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                Items
              </div>
              <ul className="mt-1 list-disc pl-5 text-sm">
                {invoice.data.items.map((it, i) => {
                  const label = variantLookup.get(it.variantId) ?? shortAddr(it.variantId, 6);
                  return (
                    <li key={i}>
                      {it.quantity.toString()}× {label} · {formatAmount(it.price, 6)} USD
                    </li>
                  );
                })}
              </ul>
            </div>
            {!customerAccountReady ? (
              <p className="text-sm text-[color:var(--color-destructive)]">
                Your PAS account isn&apos;t initialized. Return to the dashboard and
                initialize it before paying.
              </p>
            ) : null}
            {!merchantAccountReady && customerAccountReady ? (
              <p className="text-sm text-[color:var(--color-destructive)]">
                The merchant&apos;s payout account doesn&apos;t exist on chain. Contact
                the merchant to initialize it.
              </p>
            ) : null}
            {isSelfPayment ? (
              <p className="text-sm text-[color:var(--color-destructive)]">
                Your wallet is the merchant&apos;s payout address. Sui&apos;s PTB
                borrow checker rejects sending balance from an account to itself.
                Connect a different wallet to pay this invoice.
              </p>
            ) : null}
            <div className="mt-2 flex justify-end gap-2">
              <Button variant="ghost" onClick={() => setInvoiceId(null)}>
                Cancel
              </Button>
              <Button
                onClick={handlePay}
                disabled={
                  expired ||
                  isSelfPayment ||
                  pay.isPending ||
                  !customerAccountReady ||
                  !merchantAccountReady
                }
              >
                {pay.isPending ? "Paying…" : "Pay"}
              </Button>
            </div>
          </CardContent>
        </Card>
      )}
    </section>
  );
}
