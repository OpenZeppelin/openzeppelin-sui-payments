"use client";

import { useMemo, useState } from "react";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { Minus, Plus, Gift } from "lucide-react";

import { QrDisplay } from "@/components/shared/qr-display";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { qk, useBalances, useListings } from "@/hooks/queries";
import { usePasAccount } from "@/hooks/use-pas-account";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { deployment } from "@/lib/deployment";
import { buildAccountNewAuth, buildUnlockBalance } from "@/lib/move/pas";
import { buildCreateVoucher } from "@/lib/move/redemption";
import { formatAmount } from "@/lib/utils";

interface CartLine {
  variantId: string;
  variantName: string;
  listingName: string;
  loyaltyPrice: bigint;
  quantity: number;
}

export default function RewardsPage() {
  const account = useCurrentAccount();
  const customerPas = usePasAccount(account?.address);
  const balances = useBalances(customerPas.data ?? null, [deployment.loyaltyType]);
  const { data: listings = [], isLoading } = useListings();
  const [cart, setCart] = useState<Map<string, CartLine>>(new Map());
  const [voucherId, setVoucherId] = useState<string | null>(null);

  const redeemable = useMemo(
    () =>
      listings.flatMap((l) =>
        l.variants
          .filter((v) => l.active && v.loyaltyPrice !== null)
          .map((v) => ({ listing: l, variant: v, loyaltyPrice: v.loyaltyPrice! })),
      ),
    [listings],
  );

  const lines = useMemo(() => Array.from(cart.values()), [cart]);
  const total = useMemo(
    () =>
      lines.reduce((acc, l) => acc + l.loyaltyPrice * BigInt(l.quantity), 0n),
    [lines],
  );
  const totalQty = useMemo(() => lines.reduce((acc, l) => acc + l.quantity, 0), [lines]);

  const loyaltyBalance = balances.data?.[deployment.loyaltyType] ?? 0n;
  const insufficient = total > loyaltyBalance;

  function adjust(line: Omit<CartLine, "quantity">, delta: number) {
    setCart((prev) => {
      const next = new Map(prev);
      const existing = next.get(line.variantId);
      const quantity = (existing?.quantity ?? 0) + delta;
      if (quantity <= 0) next.delete(line.variantId);
      else next.set(line.variantId, { ...line, quantity });
      return next;
    });
  }

  const createVoucher = useSponsoredMutation<{
    customerAccountId: string;
    amount: bigint;
    variantIds: string[];
    quantities: bigint[];
  }>(
    (tx, args) => {
      const auth = buildAccountNewAuth(tx);
      const unlockReq = buildUnlockBalance(tx, {
        auth,
        customerAccountId: args.customerAccountId,
        amount: args.amount,
        coinType: deployment.loyaltyType,
      });
      buildCreateVoucher(tx, {
        unlockRequest: unlockReq,
        variantIds: args.variantIds,
        quantities: args.quantities,
      });
    },
    {
      invalidate: [
        qk.events(`${deployment.packageId}::events::VoucherCreated`),
        qk.balances(customerPas.data ?? ""),
      ],
      successMessage: null,
    },
  );

  async function handleCreate() {
    if (!customerPas.data || lines.length === 0) return;
    const result = await createVoucher.mutateAsync({
      customerAccountId: customerPas.data,
      amount: total,
      variantIds: lines.map((l) => l.variantId),
      quantities: lines.map((l) => BigInt(l.quantity)),
    });
    const evType = `${deployment.packageId}::events::VoucherCreated`;
    const ev = (result.events ?? []).find((e) => e.type === evType);
    const newId = (ev?.parsedJson as { voucher_id?: string } | undefined)?.voucher_id;
    if (newId) {
      setVoucherId(newId);
      setCart(new Map());
    }
  }

  return (
    <section>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Rewards</h1>
        <p className="text-sm text-[color:var(--color-muted-foreground)]">
          Spend loyalty points on items. Locks LOY into a voucher; show the QR
          to the merchant to claim.
        </p>
        <div className="mt-3 text-sm">
          <span className="text-[color:var(--color-muted-foreground)]">
            Available:
          </span>{" "}
          <strong>{formatAmount(loyaltyBalance, 0)} LOY</strong>
        </div>
      </header>

      {isLoading ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading listings…</p>
      ) : redeemable.length === 0 ? (
        <div className="rounded-lg border border-dashed border-[color:var(--color-border)] p-12 text-center text-sm text-[color:var(--color-muted-foreground)]">
          No redeemable items. The merchant hasn&apos;t set a loyalty price on
          any active variant yet.
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 pb-32 md:grid-cols-2">
          {redeemable.map(({ listing, variant, loyaltyPrice }) => {
            const qty = cart.get(variant.id)?.quantity ?? 0;
            return (
              <Card key={variant.id}>
                <CardHeader>
                  <div className="flex items-center justify-between">
                    <CardTitle>
                      {listing.name} · {variant.name}
                    </CardTitle>
                    <Badge variant="accent">{loyaltyPrice.toString()} LOY</Badge>
                  </div>
                </CardHeader>
                <CardContent className="flex items-center justify-end gap-2">
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() =>
                      adjust(
                        {
                          variantId: variant.id,
                          variantName: variant.name,
                          listingName: listing.name,
                          loyaltyPrice,
                        },
                        -1,
                      )
                    }
                    disabled={qty === 0}
                  >
                    <Minus className="h-4 w-4" />
                  </Button>
                  <span className="min-w-[1.5rem] text-center text-sm font-medium">
                    {qty}
                  </span>
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() =>
                      adjust(
                        {
                          variantId: variant.id,
                          variantName: variant.name,
                          listingName: listing.name,
                          loyaltyPrice,
                        },
                        1,
                      )
                    }
                  >
                    <Plus className="h-4 w-4" />
                  </Button>
                </CardContent>
              </Card>
            );
          })}
        </div>
      )}

      {totalQty > 0 ? (
        <div className="fixed inset-x-0 bottom-0 z-30 border-t border-[color:var(--color-border)] bg-[color:var(--color-card)]">
          <div className="mx-auto flex max-w-4xl items-center gap-4 px-6 py-4">
            <Gift className="h-5 w-5 text-[color:var(--color-primary)]" />
            <div className="flex-1">
              <div className="text-sm font-medium">
                {totalQty} item{totalQty === 1 ? "" : "s"} · {total.toString()} LOY
              </div>
              <div className="text-xs text-[color:var(--color-muted-foreground)]">
                {lines.map((l) => `${l.quantity}× ${l.listingName} / ${l.variantName}`).join(", ")}
              </div>
            </div>
            <Button
              onClick={handleCreate}
              disabled={createVoucher.isPending || insufficient || !customerPas.data}
            >
              {insufficient
                ? "Insufficient LOY"
                : createVoucher.isPending
                ? "Creating…"
                : "Create voucher"}
            </Button>
          </div>
        </div>
      ) : null}

      <Dialog open={Boolean(voucherId)} onOpenChange={(o) => !o && setVoucherId(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Show this to the merchant</DialogTitle>
            <DialogDescription>
              The merchant scans the QR + redeems. Your LOY is locked until then,
              and refunded after expiry if not redeemed.
            </DialogDescription>
          </DialogHeader>
          {voucherId ? <QrDisplay value={voucherId} label="Voucher ID" /> : null}
          <div className="flex justify-end">
            <Button variant="ghost" onClick={() => setVoucherId(null)}>
              Done
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </section>
  );
}
