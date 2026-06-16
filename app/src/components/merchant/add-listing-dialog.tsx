"use client";

import { useState } from "react";
import { Plus } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { qk } from "@/hooks/queries";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import { buildAddListing, buildAddListingVariant } from "@/lib/move/merchant";
import { buildNewListing, buildNewVariant } from "@/lib/move/listing";

interface FormState {
  name: string;
  variantName: string;
  price: string;
  loyaltyPrice: string;
}

const empty: FormState = { name: "", variantName: "", price: "", loyaltyPrice: "" };

export function AddListingDialog() {
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<FormState>(empty);

  const addListing = useSponsoredMutation(
    (tx, args: FormState) => {
      // 1. Build the listing + the first variant as PTB values.
      const listing = buildNewListing(tx, args.name);
      const variant = buildNewVariant(tx, {
        name: args.variantName,
        price: BigInt(args.price),
        loyaltyPrice: args.loyaltyPrice ? BigInt(args.loyaltyPrice) : null,
      });
      // 2. Store the listing on the Merchant and capture its runtime id.
      const listingId = buildAddListing(tx, listing);
      // 3. Attach the initial variant by chaining the captured id forward.
      buildAddListingVariant(tx, { listingId, variant });
    },
    {
      invalidate: [qk.listings()],
      successMessage: "Listing added",
    },
  );

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button>
          <Plus className="h-4 w-4" />
          Add product
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add a product</DialogTitle>
          <DialogDescription>
            Creates a new listing with one initial variant. You can add more variants later.
          </DialogDescription>
        </DialogHeader>
        <form
          className="grid gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            addListing.mutate(form, {
              onSuccess: () => {
                setForm(empty);
                setOpen(false);
              },
            });
          }}
        >
          <div className="grid gap-2">
            <Label htmlFor="al-name">Product name</Label>
            <Input
              id="al-name"
              value={form.name}
              onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
              placeholder="Black Coffee"
              required
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="al-variant">Variant name</Label>
            <Input
              id="al-variant"
              value={form.variantName}
              onChange={(e) => setForm((f) => ({ ...f, variantName: e.target.value }))}
              placeholder="Small"
              required
            />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div className="grid gap-2">
              <Label htmlFor="al-price">Price (stablecoin units)</Label>
              <Input
                id="al-price"
                type="number"
                min="1"
                value={form.price}
                onChange={(e) => setForm((f) => ({ ...f, price: e.target.value }))}
                placeholder="500"
                required
              />
            </div>
            <div className="grid gap-2">
              <Label htmlFor="al-loyalty">Loyalty price (optional)</Label>
              <Input
                id="al-loyalty"
                type="number"
                min="1"
                value={form.loyaltyPrice}
                onChange={(e) => setForm((f) => ({ ...f, loyaltyPrice: e.target.value }))}
                placeholder="50"
              />
            </div>
          </div>
          <div className="mt-2 flex justify-end gap-2">
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={addListing.isPending}>
              {addListing.isPending ? "Saving…" : "Create"}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
