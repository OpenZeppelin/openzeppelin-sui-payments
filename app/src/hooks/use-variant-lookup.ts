"use client";

import { useMemo } from "react";

import { useListings } from "@/hooks/queries";

/**
 * Cached `variant_id -> "Listing · Variant"` map, built off the current
 * catalog. Callers use it to render item labels on invoice / voucher /
 * receipt views; misses (variants removed from the catalog after the
 * invoice / voucher was created) return `undefined` so the caller can fall
 * back to a short id — receipts outlive the catalog.
 */
export function useVariantLookup(): Map<string, string> {
  const { data: listings = [] } = useListings();
  return useMemo(() => {
    const m = new Map<string, string>();
    for (const l of listings)
      for (const v of l.variants) m.set(v.id, `${l.name} · ${v.name}`);
    return m;
  }, [listings]);
}
