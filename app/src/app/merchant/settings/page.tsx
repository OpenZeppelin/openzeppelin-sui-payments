"use client";

import { useEffect, useState } from "react";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { qk, useMerchant } from "@/hooks/queries";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { buildUpdateConfig, buildUpdateDisplay } from "@/lib/move/merchant";
import { LOYALTY_FLOAT_SCALING, type Merchant } from "@/lib/move/types";

const MS_PER_MINUTE = 60_000n;

export default function MerchantSettingsPage() {
  const merchant = useMerchant();

  return (
    <section className="flex flex-col gap-6">
      <header>
        <h1 className="text-2xl font-semibold">Settings</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Each section calls a role-gated entry point. Gas is sponsored.
        </p>
      </header>

      {merchant.isLoading ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading merchant…</p>
      ) : merchant.isError || !merchant.data ? (
        <p className="text-sm text-[color:var(--color-destructive)]">
          Failed to load merchant: {merchant.error?.message ?? "not found"}
        </p>
      ) : (
        <>
          <DisplayCard merchant={merchant.data} />
          <ConfigCard merchant={merchant.data} />
        </>
      )}
    </section>
  );
}

// ---------------------------------------------------------------------------
// Display name + logo URL — MerchantRole
// ---------------------------------------------------------------------------

function DisplayCard({ merchant }: { merchant: Merchant }) {
  const [name, setName] = useState(merchant.name);
  const [logoUrl, setLogoUrl] = useState(merchant.logoUrl ?? "");
  useEffect(() => {
    setName(merchant.name);
    setLogoUrl(merchant.logoUrl ?? "");
  }, [merchant.name, merchant.logoUrl]);

  const save = useSponsoredMutation<{ name: string; logoUrl: string }>(
    (tx, args) => {
      buildUpdateDisplay(tx, {
        name: args.name,
        logoUrl: args.logoUrl ? args.logoUrl : null,
      });
    },
    { invalidate: [qk.merchant()], successMessage: "Display updated" },
  );

  const unchanged = name === merchant.name && (logoUrl || null) === (merchant.logoUrl || null);

  return (
    <Card>
      <CardHeader>
        <CardTitle>Display</CardTitle>
        <CardDescription>Storefront name + optional logo URL.</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        <div className="grid gap-2">
          <Label htmlFor="m-name">Name</Label>
          <Input
            id="m-name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="My Store"
            required
          />
        </div>
        <div className="grid gap-2">
          <Label htmlFor="m-logo">Logo URL (optional)</Label>
          <Input
            id="m-logo"
            value={logoUrl}
            onChange={(e) => setLogoUrl(e.target.value)}
            placeholder="https://example.com/logo.svg"
          />
        </div>
        <div className="flex justify-end">
          <Button
            onClick={() => save.mutate({ name, logoUrl })}
            disabled={save.isPending || unchanged || !name}
          >
            {save.isPending ? "Saving…" : "Save"}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// Payout + loyalty + TTLs — single atomic update_config call, MerchantRole-gated
// ---------------------------------------------------------------------------

/** Display-side helpers: raw u64 ↔ human decimal at `LOYALTY_FLOAT_SCALING`. */
function coefficientToDecimal(raw: bigint): string {
  // Avoid float drift for clean ratios (e.g. 1e8 → "0.1"): use bigint mod/div.
  const scale = LOYALTY_FLOAT_SCALING;
  if (raw === 0n) return "0";
  const whole = raw / scale;
  const frac = raw % scale;
  if (frac === 0n) return whole.toString();
  // Pad fractional part to 9 digits, then trim trailing zeros.
  const fracStr = frac.toString().padStart(9, "0").replace(/0+$/, "");
  return `${whole}.${fracStr}`;
}

function decimalToCoefficient(value: string): bigint | null {
  const trimmed = value.trim();
  if (!/^\d+(\.\d{1,9})?$/.test(trimmed)) return null;
  const [whole, frac = ""] = trimmed.split(".");
  const fracPadded = (frac + "000000000").slice(0, 9);
  return BigInt(whole) * LOYALTY_FLOAT_SCALING + BigInt(fracPadded);
}

function ConfigCard({ merchant }: { merchant: Merchant }) {
  const [payout, setPayout] = useState(merchant.config.payoutAddress);
  const [coefficient, setCoefficient] = useState(
    coefficientToDecimal(merchant.config.loyaltyCoefficient),
  );
  const [maxMint, setMaxMint] = useState(merchant.config.maxLoyaltyPerPayment.toString());
  const [invoiceTtlMin, setInvoiceTtlMin] = useState(
    (merchant.config.invoiceTtlMs / MS_PER_MINUTE).toString(),
  );
  const [voucherTtlMin, setVoucherTtlMin] = useState(
    (merchant.config.voucherTtlMs / MS_PER_MINUTE).toString(),
  );
  useEffect(() => {
    setPayout(merchant.config.payoutAddress);
    setCoefficient(coefficientToDecimal(merchant.config.loyaltyCoefficient));
    setMaxMint(merchant.config.maxLoyaltyPerPayment.toString());
    setInvoiceTtlMin((merchant.config.invoiceTtlMs / MS_PER_MINUTE).toString());
    setVoucherTtlMin((merchant.config.voucherTtlMs / MS_PER_MINUTE).toString());
  }, [merchant.config]);

  const save = useSponsoredMutation<{
    payoutAddress: string;
    loyaltyCoefficient: bigint;
    maxLoyaltyPerPayment: bigint;
    invoiceTtlMs: bigint;
    voucherTtlMs: bigint;
  }>((tx, args) => buildUpdateConfig(tx, args), {
    invalidate: [qk.merchant()],
    successMessage: "Config updated",
  });

  const coeffRaw = decimalToCoefficient(coefficient);
  const validPayout = /^0x[0-9a-fA-F]+$/.test(payout) && payout.length === 66;
  const canSave = coeffRaw !== null && validPayout && Boolean(maxMint && invoiceTtlMin && voucherTtlMin);

  function handleSave() {
    if (coeffRaw === null) return;
    save.mutate({
      payoutAddress: payout,
      loyaltyCoefficient: coeffRaw,
      maxLoyaltyPerPayment: BigInt(maxMint || "0"),
      invoiceTtlMs: BigInt(invoiceTtlMin || "0") * MS_PER_MINUTE,
      voucherTtlMs: BigInt(voucherTtlMin || "0") * MS_PER_MINUTE,
    });
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Payout + loyalty + TTLs</CardTitle>
        <CardDescription>
          One atomic update. The accepted payment currency is pinned at deploy
          time and can&apos;t be rotated here. Open invoices keep their
          snapshots — changes affect future issuances only.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        <div className="grid gap-2">
          <Label htmlFor="m-payout">Payout address (0x…)</Label>
          <Input
            id="m-payout"
            value={payout}
            onChange={(e) => setPayout(e.target.value.trim())}
            placeholder="0x…"
            className="font-mono text-sm"
            required
          />
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div className="grid gap-2">
            <Label htmlFor="m-coeff">Loyalty per unit</Label>
            <Input
              id="m-coeff"
              inputMode="decimal"
              value={coefficient}
              onChange={(e) => setCoefficient(e.target.value)}
              placeholder="0.1"
            />
            <p className="text-xs text-[color:var(--color-muted-foreground)]">
              LOY minted per 1 stablecoin unit (max 9 decimal places).
            </p>
          </div>
          <div className="grid gap-2">
            <Label htmlFor="m-max-mint">Max LOY per payment</Label>
            <Input
              id="m-max-mint"
              type="number"
              min="0"
              value={maxMint}
              onChange={(e) => setMaxMint(e.target.value)}
            />
          </div>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div className="grid gap-2">
            <Label htmlFor="m-inv-ttl">Invoice TTL (minutes)</Label>
            <Input
              id="m-inv-ttl"
              type="number"
              min="1"
              value={invoiceTtlMin}
              onChange={(e) => setInvoiceTtlMin(e.target.value)}
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="m-vou-ttl">Voucher TTL (minutes)</Label>
            <Input
              id="m-vou-ttl"
              type="number"
              min="1"
              value={voucherTtlMin}
              onChange={(e) => setVoucherTtlMin(e.target.value)}
            />
          </div>
        </div>
        <div className="flex justify-end">
          <Button onClick={handleSave} disabled={save.isPending || !canSave}>
            {save.isPending ? "Saving…" : "Save"}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}
