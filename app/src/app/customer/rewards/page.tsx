"use client";

import { useMemo, useState } from "react";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { Minus, Plus, Gift, RotateCcw, ScanLine } from "lucide-react";
import { toast } from "sonner";

import { VoucherStatusDialog } from "@/components/customer/voucher-status-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { qk, useBalances, useListings, useMyOpenVouchers } from "@/hooks/queries";
import { usePasAccount } from "@/hooks/use-pas-account";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { deployment } from "@/lib/deployment";
import { buildAccountNewAuth, buildUnlockBalance } from "@/lib/move/pas";
import { buildCancelVoucher, buildCreateVoucher } from "@/lib/move/redemption";
import {
  blake2b256,
  clearPreimage,
  generatePreimage,
  loadPreimage,
  savePreimage,
} from "@/lib/preimage";
import { encodeVoucherQr } from "@/lib/qr";
import { formatAmount, shortAddr } from "@/lib/utils";
import type { Voucher } from "@/lib/move/types";

interface CartLine {
  variantId: string;
  variantName: string;
  listingName: string;
  loyaltyPrice: bigint;
  quantity: number;
}

export default function RewardsPage() {
  const address = useCurrentAccount()?.address ?? null;
  const customerPas = usePasAccount(address);
  const balances = useBalances(customerPas.data ?? null, [deployment.loyaltyType]);
  const { data: listings = [], isLoading } = useListings();
  const openVouchers = useMyOpenVouchers(address);
  const [cart, setCart] = useState<Map<string, CartLine>>(new Map());
  // `created` carries the preimage in-memory so the just-created dialog never
  // depends on a localStorage round-trip — even if persistence later fails,
  // the QR still renders for this session.
  const [created, setCreated] = useState<{ id: string; preimage: Uint8Array } | null>(null);
  // `showingVoucher` holds the full Voucher so we can look up its preimage by
  // its on-chain `redeemHash` (not by voucher id).
  const [showingVoucher, setShowingVoucher] = useState<Voucher | null>(null);

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
    redeemHash: Uint8Array;
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
        redeemHash: args.redeemHash,
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

    // Generate the redemption preimage client-side and commit only its hash
    // on chain. The preimage never leaves this device until the customer
    // reveals it via the QR at the till.
    const preimage = generatePreimage();
    const redeemHash = blake2b256(preimage);

    // Persist BEFORE submission, keyed by hash. If the tx succeeds but we
    // fail to learn the voucher id (event missing from response, network
    // hiccup, page unload), the preimage is still recoverable: any later
    // read looks it up via the on-chain voucher's `redeem_hash`.
    savePreimage(redeemHash, preimage);

    let result;
    try {
      result = await createVoucher.mutateAsync({
        customerAccountId: customerPas.data,
        amount: total,
        variantIds: lines.map((l) => l.variantId),
        quantities: lines.map((l) => BigInt(l.quantity)),
        redeemHash,
      });
    } catch (err) {
      // Tx failed — no on-chain voucher exists, drop the orphan preimage so
      // localStorage doesn't accumulate entries for never-created vouchers.
      clearPreimage(redeemHash);
      throw err;
    }

    // Tx succeeded — clear cart unconditionally so the user can't
    // accidentally submit a second voucher even if the event-parse step
    // below fails. The voucher is recoverable via "Your open vouchers".
    setCart(new Map());

    const evType = `${deployment.packageId}::events::VoucherCreated`;
    const ev = (result.events ?? []).find((e) => e.type === evType);
    const newId = (ev?.parsedJson as { voucher_id?: string } | undefined)?.voucher_id;
    if (newId) setCreated({ id: newId, preimage });
  }

  // QR payload for the post-create dialog. Uses the in-memory preimage —
  // no localStorage read needed for the just-created flow.
  const justCreatedQr = useMemo(() => {
    if (!created) return null;
    return encodeVoucherQr(created.id, created.preimage);
  }, [created]);

  // QR payload for the "Show" button on an existing open voucher. Looks
  // up the preimage by the voucher's on-chain `redeemHash`.
  const showingQr = useMemo(() => {
    if (!showingVoucher) return null;
    const preimage = loadPreimage(showingVoucher.redeemHash);
    if (!preimage) return null;
    return encodeVoucherQr(showingVoucher.id, preimage);
  }, [showingVoucher]);

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

      {openVouchers.data && openVouchers.data.length > 0 ? (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Your open vouchers</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="divide-y divide-[color:var(--color-border)]">
              {openVouchers.data.map((v) => (
                <OpenVoucherRow
                  key={v.id}
                  voucher={v}
                  onShow={(voucher) => setShowingVoucher(voucher)}
                />
              ))}
            </div>
          </CardContent>
        </Card>
      ) : null}

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
                    aria-label={`Decrease quantity of ${variant.name}`}
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
                    aria-label={`Increase quantity of ${variant.name}`}
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

      {/* Post-creation QR dialog. Polls merchant.voucher_receipts and auto-
          swaps to a "Voucher redeemed" view the moment the merchant settles. */}
      <VoucherStatusDialog
        voucherId={created?.id ?? null}
        qrPayload={justCreatedQr}
        open={Boolean(created)}
        onOpenChange={(o) => !o && setCreated(null)}
      />

      {/* Re-show an existing open voucher's QR; same status-watching dialog. */}
      <VoucherStatusDialog
        voucherId={showingVoucher?.id ?? null}
        qrPayload={showingQr}
        open={Boolean(showingVoucher)}
        onOpenChange={(o) => !o && setShowingVoucher(null)}
      />
    </section>
  );
}

/** One row in "Your open vouchers" — expired vouchers get a Reclaim button. */
function OpenVoucherRow({
  voucher,
  onShow,
}: {
  voucher: Voucher;
  onShow: (voucher: Voucher) => void;
}) {
  const now = BigInt(Date.now());
  const expired = voucher.expiresAtMs <= now;
  const when = new Date(Number(voucher.expiresAtMs)).toLocaleString();

  // Customer signs cancel_voucher themselves (sponsored). The tx needs their
  // PAS account id to route the unlocked LOY back — look it up by the
  // voucher's `customer` field.
  const customerPas = usePasAccount(voucher.customer);
  const reclaim = useSponsoredMutation<{ voucherId: string; customerLoyaltyAccountId: string }>(
    (tx, args) =>
      buildCancelVoucher(tx, {
        voucherId: args.voucherId,
        customerLoyaltyAccountId: args.customerLoyaltyAccountId,
      }),
    {
      // Partial-key invalidation on `["balances"]` catches
      // `["balances", <accountId>, ...]` regardless of the coinTypes tail.
      invalidate: [
        ["my-open-vouchers", voucher.customer],
        ["balances"],
        qk.events(`${deployment.packageId}::events::VoucherCanceled`),
      ],
      successMessage: `Reclaimed ${voucher.amount.toString()} LOY`,
    },
  );

  return (
    <div className="flex items-center justify-between gap-4 py-3">
      <div className="flex items-center gap-3">
        {expired ? (
          <Badge variant="destructive">Expired</Badge>
        ) : (
          <Badge variant="accent">Open</Badge>
        )}
        <div>
          <div className="text-sm font-medium">{voucher.amount.toString()} LOY locked</div>
          <div className="text-xs text-[color:var(--color-muted-foreground)]">
            {voucher.items.length} item{voucher.items.length === 1 ? "" : "s"} ·{" "}
            <span className="font-mono">{shortAddr(voucher.id, 6)}</span>
            {" · "}
            {expired ? `expired ${when}` : `valid until ${when}`}
          </div>
        </div>
      </div>
      <div className="flex items-center gap-2">
        {!expired ? (
          <Button
            size="sm"
            variant="outline"
            onClick={() => {
              // Preimage lives in this device's localStorage, keyed by the
              // voucher's on-chain `redeem_hash`. If it's missing (browser
              // data cleared, different device, etc.) the QR can't be
              // redeemed — surface that early instead of showing a dead QR.
              if (!loadPreimage(voucher.redeemHash)) {
                toast.error(
                  "Voucher preimage missing on this device — wait for expiry and reclaim the LOY.",
                );
                return;
              }
              onShow(voucher);
            }}
          >
            <ScanLine className="h-4 w-4" />
            Show
          </Button>
        ) : (
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              reclaim.mutate({
                voucherId: voucher.id,
                customerLoyaltyAccountId: customerPas.data!,
              })
            }
            disabled={reclaim.isPending || !customerPas.data}
          >
            <RotateCcw className="h-4 w-4" />
            {reclaim.isPending ? "Reclaiming…" : "Reclaim LOY"}
          </Button>
        )}
      </div>
    </div>
  );
}
