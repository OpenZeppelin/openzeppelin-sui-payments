"use client";

import { useEffect, useState } from "react";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { qk, useMerchant } from "@/hooks/queries";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import {
  buildSetConfig,
  buildSetDisplay,
  buildSetPaymentType,
  buildSetPayoutAddress,
} from "@/lib/move/merchant";
import type { Merchant } from "@/lib/move/types";

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
          <PayoutCard merchant={merchant.data} />
          <ConfigCard merchant={merchant.data} />
          <PaymentTypeCard merchant={merchant.data} />
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
      buildSetDisplay(tx, {
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
// Payout address — MerchantRole
// ---------------------------------------------------------------------------

function PayoutCard({ merchant }: { merchant: Merchant }) {
  const [addr, setAddr] = useState(merchant.payoutAddress);
  useEffect(() => setAddr(merchant.payoutAddress), [merchant.payoutAddress]);

  const save = useSponsoredMutation<string>(
    (tx, next) => buildSetPayoutAddress(tx, next),
    { invalidate: [qk.merchant()], successMessage: "Payout address updated" },
  );

  const unchanged = addr === merchant.payoutAddress;
  const validAddr = /^0x[0-9a-fA-F]+$/.test(addr) && addr.length === 66;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Payout address</CardTitle>
        <CardDescription>
          Address that receives customer stablecoin on settlement. Change rotates
          where future invoices route — open invoices keep their snapshot.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        <div className="grid gap-2">
          <Label htmlFor="m-payout">Address (0x…)</Label>
          <Input
            id="m-payout"
            value={addr}
            onChange={(e) => setAddr(e.target.value.trim())}
            placeholder="0x…"
            className="font-mono text-sm"
            required
          />
        </div>
        <div className="flex justify-end">
          <Button
            onClick={() => save.mutate(addr)}
            disabled={save.isPending || unchanged || !validAddr}
          >
            {save.isPending ? "Saving…" : "Save"}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// Loyalty config + TTLs — MerchantRole
// ---------------------------------------------------------------------------

function ConfigCard({ merchant }: { merchant: Merchant }) {
  const [mintN, setMintN] = useState(merchant.config.mintNumerator.toString());
  const [mintD, setMintD] = useState(merchant.config.mintDenominator.toString());
  const [maxMint, setMaxMint] = useState(merchant.config.maxMintPerPayment.toString());
  const [invoiceTtlMin, setInvoiceTtlMin] = useState(
    (merchant.config.invoiceTtlMs / MS_PER_MINUTE).toString(),
  );
  const [voucherTtlMin, setVoucherTtlMin] = useState(
    (merchant.config.voucherTtlMs / MS_PER_MINUTE).toString(),
  );
  useEffect(() => {
    setMintN(merchant.config.mintNumerator.toString());
    setMintD(merchant.config.mintDenominator.toString());
    setMaxMint(merchant.config.maxMintPerPayment.toString());
    setInvoiceTtlMin((merchant.config.invoiceTtlMs / MS_PER_MINUTE).toString());
    setVoucherTtlMin((merchant.config.voucherTtlMs / MS_PER_MINUTE).toString());
  }, [merchant.config]);

  const save = useSponsoredMutation<{
    mintNumerator: bigint;
    mintDenominator: bigint;
    maxMintPerPayment: bigint;
    invoiceTtlMs: bigint;
    voucherTtlMs: bigint;
  }>((tx, args) => buildSetConfig(tx, args), {
    invalidate: [qk.merchant()],
    successMessage: "Config updated",
  });

  function handleSave() {
    save.mutate({
      mintNumerator: BigInt(mintN || "0"),
      mintDenominator: BigInt(mintD || "1"),
      maxMintPerPayment: BigInt(maxMint || "0"),
      invoiceTtlMs: BigInt(invoiceTtlMin || "0") * MS_PER_MINUTE,
      voucherTtlMs: BigInt(voucherTtlMin || "0") * MS_PER_MINUTE,
    });
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Loyalty + TTLs</CardTitle>
        <CardDescription>
          Mint ratio is loyalty per stablecoin unit. Cap and TTLs prevent
          runaway mints / stale invoices &amp; vouchers.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        <div className="grid grid-cols-2 gap-4">
          <div className="grid gap-2">
            <Label htmlFor="m-mint-n">Mint numerator</Label>
            <Input
              id="m-mint-n"
              type="number"
              min="0"
              value={mintN}
              onChange={(e) => setMintN(e.target.value)}
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="m-mint-d">Mint denominator</Label>
            <Input
              id="m-mint-d"
              type="number"
              min="1"
              value={mintD}
              onChange={(e) => setMintD(e.target.value)}
            />
          </div>
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
          <Button onClick={handleSave} disabled={save.isPending}>
            {save.isPending ? "Saving…" : "Save"}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}

// ---------------------------------------------------------------------------
// Accepted payment type — MerchantRole (dangerous: rotates the coin currency)
// ---------------------------------------------------------------------------

function PaymentTypeCard({ merchant }: { merchant: Merchant }) {
  const [next, setNext] = useState(merchant.acceptedPaymentType);
  useEffect(() => setNext(merchant.acceptedPaymentType), [merchant.acceptedPaymentType]);

  const save = useSponsoredMutation<string>(
    (tx, ty) => buildSetPaymentType(tx, ty),
    { invalidate: [qk.merchant()], successMessage: "Payment type updated" },
  );

  const unchanged = next === merchant.acceptedPaymentType;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Accepted payment type</CardTitle>
        <CardDescription>
          Fully-qualified Move type, e.g. <code>0x…::stablecoin_mock::STABLECOIN_MOCK</code>.
          Changing this only affects <strong>future</strong> invoices; open invoices
          retain their snapshotted type and abort if you change it before they settle.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        <div className="grid gap-2">
          <Label htmlFor="m-pay-type">Type</Label>
          <Input
            id="m-pay-type"
            value={next}
            onChange={(e) => setNext(e.target.value.trim())}
            placeholder="0x…::stablecoin_mock::STABLECOIN_MOCK"
            className="font-mono text-sm"
          />
        </div>
        <div className="flex justify-end">
          <Button
            onClick={() => save.mutate(next)}
            disabled={save.isPending || unchanged || !next}
            variant="destructive"
          >
            {save.isPending ? "Saving…" : "Save"}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}
