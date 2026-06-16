"use client";

import { useState, useMemo } from "react";
import { Minus, Plus, ShoppingCart } from "lucide-react";
import type { SuiObjectChange } from "@mysten/sui/client";

import { AddListingDialog } from "@/components/merchant/add-listing-dialog";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { qk, useListings } from "@/hooks/queries";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { buildPaymentNewAndShare } from "@/lib/move/payment";
import { deployment } from "@/lib/deployment";

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

  const createSale = useSponsoredMutation(
    (tx, args: { lines: CartLine[]; orderRef: string }) => {
      buildPaymentNewAndShare(tx, {
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
    const invoiceType = `${deployment.packageId}::payment::Invoice`;
    const created = (result.objectChanges ?? []).find(
      (c: SuiObjectChange) => c.type === "created" && c.objectType === invoiceType,
    );
    if (created && "objectId" in created) {
      setInvoiceId(created.objectId);
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
                <div className="flex items-center justify-between">
                  <CardTitle>{listing.name}</CardTitle>
                  {listing.active ? null : <Badge variant="muted">Inactive</Badge>}
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
                            {v.price.toString()} stable
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
                {totalQty} item{totalQty === 1 ? "" : "s"} · {total.toString()} stable
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

      {/* Invoice QR popup */}
      <Dialog open={Boolean(invoiceId)} onOpenChange={(o) => !o && setInvoiceId(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Show this to the customer</DialogTitle>
            <DialogDescription>
              They scan to pay. The invoice expires in 10 minutes.
            </DialogDescription>
          </DialogHeader>
          {invoiceId ? <QrDisplay value={invoiceId} label="Invoice ID" /> : null}
          <div className="flex justify-end">
            <Button variant="ghost" onClick={() => setInvoiceId(null)}>
              Done
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </section>
  );
}
