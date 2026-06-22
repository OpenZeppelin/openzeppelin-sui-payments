"use client";

import { Eye, EyeOff, Trash2 } from "lucide-react";

import { AddVariantDialog } from "@/components/merchant/add-variant-dialog";
import { Button } from "@/components/ui/button";
import { qk } from "@/hooks/queries";
import { useSponsoredMutation } from "@/hooks/use-sponsored-mutation";
import {
  buildRemoveListing,
  buildSetListingStatus,
} from "@/lib/move/merchant";
import type { Listing } from "@/lib/move/types";

/**
 * Per-listing management controls — toggle active, add a variant, delete.
 * Rendered in the listing card's header. All actions go through
 * `useSponsoredMutation`, so the merchant signs (CatalogManagerRole) and
 * the sponsor pays gas.
 */
export function ListingActions({ listing }: { listing: Listing }) {
  const toggleStatus = useSponsoredMutation<{ listingId: string; active: boolean }>(
    (tx, args) => {
      buildSetListingStatus(tx, args);
    },
    { invalidate: [qk.listings()], successMessage: null },
  );

  const removeListing = useSponsoredMutation<string>(
    (tx, listingId) => buildRemoveListing(tx, listingId),
    { invalidate: [qk.listings()], successMessage: "Listing removed" },
  );

  return (
    <div className="flex items-center gap-1">
      <Button
        variant="ghost"
        size="icon"
        title={listing.active ? "Deactivate" : "Activate"}
        onClick={() =>
          toggleStatus.mutate({
            listingId: listing.id,
            active: !listing.active,
          })
        }
        disabled={toggleStatus.isPending}
      >
        {listing.active ? (
          <Eye className="h-4 w-4" />
        ) : (
          <EyeOff className="h-4 w-4 text-[color:var(--color-muted-foreground)]" />
        )}
      </Button>

      <AddVariantDialog listingId={listing.id} />

      <Button
        variant="ghost"
        size="icon"
        title="Remove listing"
        onClick={() => {
          if (
            window.confirm(
              `Remove "${listing.name}" and all its variants? Open invoices keep their snapshot, ` +
                `but no new invoices can reference these variants.`,
            )
          ) {
            removeListing.mutate(listing.id);
          }
        }}
        disabled={removeListing.isPending}
      >
        <Trash2 className="h-4 w-4 text-[color:var(--color-destructive)]" />
      </Button>
    </div>
  );
}
