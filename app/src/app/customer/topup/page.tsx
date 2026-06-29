"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { qk } from "@/hooks/queries";
import { usePasAccount } from "@/hooks/use-pas-account";
import { STABLECOIN_DECIMALS, formatAmount, shortAddr, toBaseUnits } from "@/lib/utils";

const QUICK_AMOUNTS = ["10", "50", "100"];

export default function TopupPage() {
  const account = useCurrentAccount();
  const pas = usePasAccount(account?.address);
  const queryClient = useQueryClient();
  const router = useRouter();

  const [amount, setAmount] = useState("");

  const topup = useMutation({
    mutationFn: async ({ amount, recipientAccountId }: { amount: bigint; recipientAccountId: string }) => {
      const resp = await fetch("/api/topup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          recipientAccountId,
          amount: amount.toString(),
        }),
      });
      if (!resp.ok) {
        const err = (await resp.json().catch(() => null)) as { error?: string } | null;
        throw new Error(err?.error ?? `topup failed (${resp.status})`);
      }
      return (await resp.json()) as { digest: string; amount: string };
    },
    onSuccess: (data) => {
      const minted = BigInt(data.amount);
      toast.success(`Topped up ${formatAmount(minted, STABLECOIN_DECIMALS)} USD`);
      void queryClient.invalidateQueries({ queryKey: qk.balances(pas.data ?? "") });
      router.push("/customer");
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Top up failed");
    },
  });

  async function handleTopup() {
    if (!pas.data) {
      toast.error("Initialize your PAS account first");
      return;
    }
    let units: bigint;
    try {
      units = toBaseUnits(amount, STABLECOIN_DECIMALS);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Invalid amount");
      return;
    }
    await topup.mutateAsync({ amount: units, recipientAccountId: pas.data });
  }

  const accountReady = pas.data !== null && pas.data !== undefined;

  return (
    <section className="flex flex-col gap-6">
      <header>
        <h1 className="text-2xl font-semibold">Top up</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Mint demo stablecoin into your PAS account. Backed by the deployer&apos;s
          TreasuryCap — this is a faucet, not a real on-ramp.
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardDescription>Recipient PAS account</CardDescription>
          <CardTitle className="font-mono text-sm">
            {pas.data ? shortAddr(pas.data, 8) : "—"}
          </CardTitle>
        </CardHeader>
        <CardContent className="grid gap-4">
          {!accountReady ? (
            <p className="text-sm text-[color:var(--color-destructive)]">
              Initialize your PAS account from the dashboard before topping up.
            </p>
          ) : null}
          <div className="grid gap-2">
            <Label htmlFor="topup-amount">Amount (USD)</Label>
            <Input
              id="topup-amount"
              type="text"
              inputMode="decimal"
              placeholder="50"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              disabled={!accountReady || topup.isPending}
            />
            <div className="flex gap-2">
              {QUICK_AMOUNTS.map((q) => (
                <Button
                  key={q}
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => setAmount(q)}
                  disabled={!accountReady || topup.isPending}
                >
                  +{q}
                </Button>
              ))}
            </div>
          </div>
          <div className="flex justify-end">
            <Button
              onClick={handleTopup}
              disabled={!accountReady || topup.isPending || !amount}
            >
              {topup.isPending ? "Topping up…" : "Top up"}
            </Button>
          </div>
        </CardContent>
      </Card>
    </section>
  );
}
