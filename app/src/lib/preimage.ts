"use client";

// `@noble/hashes` v2 publishes ESM with explicit `.js` subpaths in its
// `exports` map (`"./blake2.js": "./blake2.js"`); the suffix is required.
import { blake2b } from "@noble/hashes/blake2.js";

/**
 * Hashlock helpers for voucher redemption.
 *
 * Each voucher commits a 32-byte blake2b256 digest of a customer-chosen
 * secret preimage. The contract requires the matching preimage to redeem;
 * the cashier learns it only via the QR shown at the till, so a cashier
 * observing the voucher id from public events alone cannot sweep vouchers.
 *
 * Preimages are persisted in `localStorage` keyed by voucher id. Clearing
 * site data, switching browsers, or switching devices loses the preimage
 * (and therefore the voucher's redemption path) — `cancel_voucher` after
 * expiry is the only recovery in that case.
 */

const PREIMAGE_LENGTH = 32;
const LOCALSTORAGE_PREFIX = "voucher-preimage:";

export function generatePreimage(): Uint8Array {
  const out = new Uint8Array(PREIMAGE_LENGTH);
  crypto.getRandomValues(out);
  return out;
}

/** blake2b256 — Sui-native, matches `sui::hash::blake2b256` in `merchant::redeem`. */
export function blake2b256(data: Uint8Array): Uint8Array {
  return blake2b(data, { dkLen: 32 });
}

export function toHex(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, "0");
  return s;
}

export function fromHex(hex: string): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (clean.length % 2 !== 0) throw new Error("hex length must be even");
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// ---------------------------------------------------------------------------
// localStorage persistence
// ---------------------------------------------------------------------------

export function savePreimage(voucherId: string, preimage: Uint8Array): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(LOCALSTORAGE_PREFIX + voucherId, toHex(preimage));
}

export function loadPreimage(voucherId: string): Uint8Array | null {
  if (typeof window === "undefined") return null;
  const hex = window.localStorage.getItem(LOCALSTORAGE_PREFIX + voucherId);
  if (!hex) return null;
  try {
    return fromHex(hex);
  } catch {
    return null;
  }
}

export function clearPreimage(voucherId: string): void {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(LOCALSTORAGE_PREFIX + voucherId);
}

// QR payload encoding for invoices and vouchers lives in `lib/qr.ts`.
