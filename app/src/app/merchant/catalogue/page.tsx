"use client";

import { useState, useMemo } from "react";
import { Minus, Plus, ShoppingCart, X } from "lucide-react";

import { AddListingDialog } from "@/components/merchant/add-listing-dialog";
import { InvoiceStatusDialog } from "@/components/merchant/invoice-status-dialog";
import { ListingActions } from "@/components/merchant/listing-actions";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { qk, useListings } from "@/hooks/queries";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { buildCreateInvoice } from "@/lib/move/payment";
import { buildRemoveListingVariant } from "@/lib/move/merchant";
import { deployment } from "@/lib/deployment";
import { STABLECOIN_DECIMALS, formatAmount } from "@/lib/utils";

interface CartLine {
  variantId: string;
  variantName: string;
  listingName: string;
  price: bigint;
  loyaltyPrice: bigint | null;
  quantity: number;
}

export default function CataloguePage() {
  const { data: listings = [], isLoading } = useListings();
  const [cart, setCart] = useState<Map<string, CartLine>>(new Map());
  const [orderRef, setOrderRef] = useState("");
  const [invoiceId, setInvoiceId] = useState<string | null>(null);

  // Single mutation reused for every variant remove (the cart entry, if any,
  // is cleared optimistically). Sponsored so the merchant doesn't pay gas.
  const removeVariant = useSponsoredMutation<string>(
    (tx, variantId) => buildRemoveListingVariant(tx, variantId),
    { invalidate: [qk.listings()], successMessage: null },
  );

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

  const lines = useMemo(() => Array.from(cart.values()), [cart]);
  const total = useMemo(
    () => lines.reduce((acc, l) => acc + l.price * BigInt(l.quantity), 0n),
    [lines],
  );
  const totalQty = useMemo(() => lines.reduce((acc, l) => acc + l.quantity, 0), [lines]);

  const createSale = useSponsoredMutation<{ lines: CartLine[]; orderRef: string }>(
    (tx, args) => {
      buildCreateInvoice(tx, {
        variantIds: args.lines.map((l) => l.variantId),
        quantities: args.lines.map((l) => BigInt(l.quantity)),
        orderRef: args.orderRef,
      });
    },
    {
      invalidate: [qk.events(`${deployment.packageId}::events::InvoiceCreated`)],
      successMessage: null, // we surface the QR popup instead
    },
  );

  async function handleCreateSale() {
    const result = await createSale.mutateAsync({
      lines,
      orderRef: orderRef || `order-${Date.now()}`,
    });
    // Invoice is now stored inside Merchant.invoices keyed by a freshly-minted
    // ID. The `InvoiceCreated` event carries that ID in `parsedJson.invoice_id`.
    const invoiceCreatedType = `${deployment.packageId}::events::InvoiceCreated`;
    const ev = (result.events ?? []).find((e) => e.type === invoiceCreatedType);
    const newInvoiceId = (ev?.parsedJson as { invoice_id?: string } | undefined)?.invoice_id;
    if (newInvoiceId) {
      setInvoiceId(newInvoiceId);
      setCart(new Map());
      setOrderRef("");
    }
  }

  return (
    <section>
      <header className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Catalogue</h1>
          <p className="text-sm text-[color:var(--color-muted-foreground)]">
            Manage listings and variants. Tap +/− to build a sale.
          </p>
        </div>
        <AddListingDialog />
      </header>

      {isLoading ? (
        <p className="text-sm text-[color:var(--color-muted-foreground)]">Loading listings…</p>
      ) : listings.length === 0 ? (
        <div className="rounded-lg border border-dashed border-[color:var(--color-border)] p-12 text-center text-sm text-[color:var(--color-muted-foreground)]">
          No listings yet. Click <strong>Add product</strong> to create one.
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 pb-32 md:grid-cols-2 xl:grid-cols-3">
          {listings.map((listing) => (
            <Card key={listing.id}>
              <CardHeader>
                <div className="flex items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <CardTitle>{listing.name}</CardTitle>
                    {listing.active ? null : <Badge variant="muted">Inactive</Badge>}
                  </div>
                  <ListingActions listing={listing} />
                </div>
              </CardHeader>
              <CardContent className="flex flex-col gap-2">
                {listing.variants.length === 0 ? (
                  <p className="text-sm text-[color:var(--color-muted-foreground)]">
                    No variants
                  </p>
                ) : (
                  listing.variants.map((v) => {
                    const qty = cart.get(v.id)?.quantity ?? 0;
                    return (
                      <div
                        key={v.id}
                        className="flex items-center justify-between rounded-md border border-[color:var(--color-border)] px-3 py-2"
                      >
                        <div>
                          <div className="font-medium">{v.name}</div>
                          <div className="text-xs text-[color:var(--color-muted-foreground)]">
                            {formatAmount(v.price, STABLECOIN_DECIMALS)} USD
                            {v.loyaltyPrice ? ` · ${v.loyaltyPrice} LOY` : ""}
                          </div>
                        </div>
                        <div className="flex items-center gap-2">
                          <Button
                            variant="ghost"
                            size="icon"
                            onClick={() =>
                              adjust(
                                {
                                  variantId: v.id,
                                  variantName: v.name,
                                  listingName: listing.name,
                                  price: v.price,
                                  loyaltyPrice: v.loyaltyPrice,
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
                                  variantId: v.id,
                                  variantName: v.name,
                                  listingName: listing.name,
                                  price: v.price,
                                  loyaltyPrice: v.loyaltyPrice,
                                },
                                1,
                              )
                            }
                            disabled={!listing.active}
                          >
                            <Plus className="h-4 w-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            title="Remove variant"
                            onClick={() => {
                              if (
                                window.confirm(
                                  `Remove "${v.name}" from "${listing.name}"?`,
                                )
                              ) {
                                // Clear from cart first so a stale entry can't
                                // be checked out after the remove confirms.
                                setCart((prev) => {
                                  const next = new Map(prev);
                                  next.delete(v.id);
                                  return next;
                                });
                                removeVariant.mutate(v.id);
                              }
                            }}
                            disabled={removeVariant.isPending}
                          >
                            <X className="h-4 w-4 text-[color:var(--color-destructive)]" />
                          </Button>
                        </div>
                      </div>
                    );
                  })
                )}
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      {/* Sticky checkout footer */}
      {totalQty > 0 ? (
        <div className="fixed inset-x-0 bottom-0 z-30 border-t border-[color:var(--color-border)] bg-[color:var(--color-card)]">
          <div className="mx-auto flex max-w-5xl items-center gap-4 px-6 py-4">
            <ShoppingCart className="h-5 w-5 text-[color:var(--color-primary)]" />
            <div className="flex-1">
              <div className="text-sm font-medium">
                {totalQty} item{totalQty === 1 ? "" : "s"} ·{" "}
                {formatAmount(total, STABLECOIN_DECIMALS)} USD
              </div>
              <div className="text-xs text-[color:var(--color-muted-foreground)]">
                {lines.map((l) => `${l.quantity}× ${l.listingName} / ${l.variantName}`).join(", ")}
              </div>
            </div>
            <div className="w-40">
              <Input
                placeholder="Order ref (optional)"
                value={orderRef}
                onChange={(e) => setOrderRef(e.target.value)}
              />
            </div>
            <Button onClick={handleCreateSale} disabled={createSale.isPending}>
              {createSale.isPending ? "Creating…" : "Create sale"}
            </Button>
          </div>
        </div>
      ) : null}

      {/* Shows the QR while waiting for payment; auto-swaps to a receipt summary
          when the customer settles (polls merchant.invoice_receipts). */}
      <InvoiceStatusDialog
        invoiceId={invoiceId}
        open={Boolean(invoiceId)}
        onOpenChange={(o) => !o && setInvoiceId(null)}
      />
    </section>
  );
}
