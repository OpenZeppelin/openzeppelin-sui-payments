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
  const [whole, fraction = ""] = trimmed.split(".");
  if (fraction.length > decimals) {
    throw new Error(`max ${decimals} fractional digits`);
  }
  const padded = (fraction + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
}
