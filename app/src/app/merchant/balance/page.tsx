"use client";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { useBalances, useMerchant } from "@/hooks/queries";
import { usePasAccount } from "@/hooks/use-pas-account";
import { deployment } from "@/lib/deployment";
import { shortAddr, formatAmount } from "@/lib/utils";

export default function BalancePage() {
  const merchant = useMerchant();
  const payoutAddress = merchant.data?.config.payoutAddress ?? null;
  const payoutAccount = usePasAccount(payoutAddress);
  const balances = useBalances(payoutAccount.data ?? null, [deployment.stablecoinType]);

  const stable = balances.data?.[deployment.stablecoinType] ?? 0n;

  return (
    <section>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Balance</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Stablecoin held by the merchant&apos;s payout PAS account.
        </p>
      </header>

      {merchant.isError ? (
        <p className="text-sm text-[color:var(--color-destructive)]">
          Could not load merchant: {merchant.error?.message ?? "unknown error"}
        </p>
      ) : merchant.isLoading ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading merchant…</p>
      ) : (
        <>
          <Card>
            <CardHeader>
              <CardDescription>Payout address</CardDescription>
              <CardTitle className="font-mono text-sm">
                {payoutAddress ? shortAddr(payoutAddress, 8) : "—"}
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div>
                <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
                  Stablecoin
                </div>
                <div className="mt-1 text-3xl font-semibold">
                  {balances.isLoading ? "…" : formatAmount(stable, 6)} USD
                </div>
              </div>
            </CardContent>
          </Card>

          {payoutAccount.data === null && !payoutAccount.isLoading ? (
            <p className="mt-4 text-xs text-[color:var(--color-muted-foreground)]">
              The payout address has no PAS account yet. Once a customer pays an invoice, PAS will
              create it automatically.
            </p>
          ) : null}
        </>
      )}
    </section>
  );
}
