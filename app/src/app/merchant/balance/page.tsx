"use client";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { useBalances, useMerchant } from "@/hooks/queries";
import { usePasAccount } from "@/hooks/use-pas-account";
import { deployment } from "@/lib/deployment";
import { shortAddr, formatAmount } from "@/lib/utils";

export default function BalancePage() {
  const merchant = useMerchant();
  const payoutAddress = merchant.data?.payoutAddress ?? null;
  const payoutAccount = usePasAccount(payoutAddress);
  const balances = useBalances(payoutAccount.data ?? null, [
    deployment.stablecoinType,
    deployment.loyaltyType,
  ]);

  const stable = balances.data?.[deployment.stablecoinType] ?? 0n;
  const loyalty = balances.data?.[deployment.loyaltyType] ?? 0n;

  return (
    <section>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Balance</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Stablecoin held by the merchant's payout PAS account.
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardDescription>Payout address</CardDescription>
          <CardTitle className="font-mono text-sm">
            {payoutAddress ? shortAddr(payoutAddress, 8) : "—"}
          </CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-2 gap-6">
          <div>
            <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
              Stablecoin
            </div>
            <div className="mt-1 text-3xl font-semibold">
              {balances.isLoading ? "…" : formatAmount(stable, 6)} USD
            </div>
          </div>
          <div>
            <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
              Loyalty (held by merchant)
            </div>
            <div className="mt-1 text-3xl font-semibold">
              {balances.isLoading ? "…" : formatAmount(loyalty, 0)} LOY
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
    </section>
  );
}
