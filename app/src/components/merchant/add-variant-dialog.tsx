"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { toast } from "sonner";

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
import { buildAddListingVariant } from "@/lib/move/merchant";
import { buildNewVariant } from "@/lib/move/listing";
import { STABLECOIN_DECIMALS, toBaseUnits } from "@/lib/utils";

interface FormState {
  variantName: string;
  price: string;
  loyaltyPrice: string;
}

const empty: FormState = { variantName: "", price: "", loyaltyPrice: "" };

/**
 * Adds a variant to an *existing* listing. Sibling to the AddListingDialog,
 * but skipping the listing-create step — the listing id is passed in.
 */
export function AddVariantDialog({ listingId }: { listingId: string }) {
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<FormState>(empty);

  const addVariant = useSponsoredMutation<FormState>(
    (tx, args) => {
      const variant = buildNewVariant(tx, {
        name: args.variantName,
        price: toBaseUnits(args.price, STABLECOIN_DECIMALS),
        loyaltyPrice: args.loyaltyPrice ? BigInt(args.loyaltyPrice) : null,
      });
      buildAddListingVariant(tx, { listingId, variant });
    },
    { invalidate: [qk.listings()], successMessage: "Variant added" },
  );

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="icon" title="Add variant">
          <Plus className="h-4 w-4" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add a variant</DialogTitle>
          <DialogDescription>
            Adds a new variant (size / option) to this listing.
          </DialogDescription>
        </DialogHeader>
        <form
          className="grid gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            // `type=number` allows "1.5" and "1e3" — both would throw an ugly
            // Cannot-convert error from BigInt() downstream. Reject up front.
            // `[1-9]\d*` rejects `0` as well as non-digit input — `0 LOY`
            // is almost certainly a "meant to leave blank" mistake, and
            // "0 LOY per redemption" would produce a nonsense free voucher.
            if (form.loyaltyPrice && !/^[1-9]\d*$/.test(form.loyaltyPrice.trim())) {
              toast.error("Loyalty price must be a positive integer.");
              return;
            }
            addVariant.mutate(form, {
              onSuccess: () => {
                setForm(empty);
                setOpen(false);
              },
            });
          }}
        >
          <div className="grid gap-2">
            <Label htmlFor="av-name">Variant name</Label>
            <Input
              id="av-name"
              value={form.variantName}
              onChange={(e) => setForm((f) => ({ ...f, variantName: e.target.value }))}
              placeholder="Large"
              required
            />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div className="grid gap-2">
              <Label htmlFor="av-price">Price (USD)</Label>
              <Input
                id="av-price"
                type="text"
                inputMode="decimal"
                value={form.price}
                onChange={(e) => setForm((f) => ({ ...f, price: e.target.value }))}
                placeholder="5.00"
                required
              />
            </div>
            <div className="grid gap-2">
              <Label htmlFor="av-loyalty">Loyalty price (optional)</Label>
              <Input
                id="av-loyalty"
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
            <Button type="submit" disabled={addVariant.isPending}>
              {addVariant.isPending ? "Saving…" : "Add"}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
