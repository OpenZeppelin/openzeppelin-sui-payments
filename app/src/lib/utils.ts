import { type ClassValue, clsx } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function shortAddr(addr: string, chars = 4): string {
  if (addr.length <= 2 + chars * 2) return addr;
  return `${addr.slice(0, 2 + chars)}…${addr.slice(-chars)}`;
}

/**
 * Format receipt line items as a compact "Listing · Variant" list, one entry
 * per line item, quantity-prefixed if > 1. Variants that have since been
 * removed from the catalog fall back to their short variant id — receipts
 * outlive the catalog, so lookup misses are normal. Callers pass the current
 * `useListings().data` array; a missing/empty catalog collapses to short ids.
 */
export function formatItems(
  items: readonly { variantId: string; quantity: bigint }[],
  listings: readonly { name: string; variants: readonly { id: string; name: string }[] }[],
): string {
  const lookup = new Map<string, { listing: string; variant: string }>();
  for (const l of listings)
    for (const v of l.variants) lookup.set(v.id, { listing: l.name, variant: v.name });
  return items
    .map((it) => {
      const qty = it.quantity > 1n ? `${it.quantity}× ` : "";
      const hit = lookup.get(it.variantId);
      return hit ? `${qty}${hit.listing} · ${hit.variant}` : `${qty}${shortAddr(it.variantId, 6)}`;
    })
    .join(", ");
}

/**
 * Decimal places used by the mock stablecoin (matches `stablecoin_mock::init`,
 * which calls `new_currency_with_otw(..., 6, ...)`). All UI conversions between
 * human-entered amounts (e.g. "500") and on-chain u64 base units go through
 * `formatAmount`/`toBaseUnits` with this constant.
 */
export const STABLECOIN_DECIMALS = 6;

export function formatAmount(units: bigint | number, decimals: number): string {
  const u = typeof units === "bigint" ? units : BigInt(units);
  const base = 10n ** BigInt(decimals);
  const whole = u / base;
  const fraction = u % base;
  if (fraction === 0n) return whole.toString();
  const fracStr = fraction.toString().padStart(decimals, "0").replace(/0+$/, "");
  return fracStr ? `${whole}.${fracStr}` : whole.toString();
}

/**
 * Inverse of `formatAmount` — convert a human decimal string ("500.50") to
 * u64 base units (multiplied by 10**decimals). Throws on too many fractional
 * digits or unparsable input.
 */
export function toBaseUnits(human: string, decimals: number): bigint {
  const trimmed = human.trim();
  if (!trimmed) throw new Error("amount required");
  // Strict shape check: integer, "N.M" decimal, or ".M" leading-dot decimal.
  // `split(".")` alone happily turns "1.2.3" into 1.200000 (taking just the
  // first two segments) and "." into 0 — both should surface as user errors
  // rather than silently submit the wrong amount.
  if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(trimmed)) {
    throw new Error("invalid amount");
  }
  const [whole, fraction = ""] = trimmed.split(".");
  if (fraction.length > decimals) {
    throw new Error(`max ${decimals} fractional digits`);
  }
  const padded = (fraction + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
}
