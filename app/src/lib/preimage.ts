"use client";

// `@noble/hashes` v2 publishes ESM with explicit `.js` subpaths in its
// `exports` map (`"./blake2.js": "./blake2.js"`); the suffix is required.
import { blake2b } from "@noble/hashes/blake2.js";
import { fromHex, toHex } from "@mysten/sui/utils";

/**
 * Hashlock helpers for voucher redemption.
 *
 * Each voucher commits a 32-byte blake2b256 digest of a customer-chosen
 * secret preimage. The contract requires the matching preimage to redeem;
 * the cashier learns it only via the QR shown at the till, so a cashier
 * observing the voucher id from public events alone cannot sweep vouchers.
 *
 * Preimages are persisted in `localStorage` keyed by the on-chain `redeem_hash`
 * commitment. Keying by hash (not voucher id) means the entry is written BEFORE
 * `create_voucher` is submitted — a tx-side failure to learn the voucher id
 * (event missing from response, network hiccup, page unload mid-tx) does not
 * leave an unredeemable on-chain voucher: any later read looks up the preimage
 * by the voucher's stored `redeem_hash`.
 *
 * Clearing site data, switching browsers, or switching devices loses the
 * preimage (and therefore the voucher's redemption path) — `cancel_voucher`
 * after expiry is the only recovery in that case.
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

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// ---------------------------------------------------------------------------
// localStorage persistence
// ---------------------------------------------------------------------------

export function savePreimage(redeemHash: Uint8Array, preimage: Uint8Array): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(LOCALSTORAGE_PREFIX + toHex(redeemHash), toHex(preimage));
}

export function loadPreimage(redeemHash: Uint8Array): Uint8Array | null {
  if (typeof window === "undefined") return null;
  const hex = window.localStorage.getItem(LOCALSTORAGE_PREFIX + toHex(redeemHash));
  if (!hex) return null;
  try {
    return fromHex(hex);
  } catch {
    return null;
  }
}

export function clearPreimage(redeemHash: Uint8Array): void {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(LOCALSTORAGE_PREFIX + toHex(redeemHash));
}

// QR payload encoding for invoices and vouchers lives in `lib/qr.ts`.
