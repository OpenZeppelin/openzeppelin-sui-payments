import { fromHex, toHex } from "@/lib/preimage";

/**
 * QR payload codecs for invoice and voucher flows.
 *
 * Both payloads are raw bytes encoded as RFC 4648 base32 without padding.
 * base32's alphabet (`A-Z`, `2-7`) falls entirely inside QR's alphanumeric
 * character set, so the QR library encodes the payload at 5.5 bits/char
 * instead of the 8 bits/char that byte mode would use — about 30 % fewer
 * scan bits than base64 for the same number of bytes.
 *
 *   - Invoice: 32-byte Sui ObjectId          → 52 chars
 *   - Voucher: 32-byte id ‖ 32-byte preimage → 103 chars
 *
 * Length disambiguates the two payloads if a caller ever needs to.
 */

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const INVOICE_BYTES = 32;
const VOUCHER_BYTES = 64;

function encodeBase32(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    value = (value << 8) | bytes[i];
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += ALPHABET[(value >> bits) & 0x1f];
    }
  }
  if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 0x1f];
  return out;
}

function decodeBase32(s: string): Uint8Array {
  const clean = s.trim().toUpperCase();
  const out = new Uint8Array(Math.floor((clean.length * 5) / 8));
  let bits = 0;
  let value = 0;
  let idx = 0;
  for (let i = 0; i < clean.length; i++) {
    const v = ALPHABET.indexOf(clean[i]);
    if (v < 0) throw new Error(`invalid base32 char at ${i}: ${clean[i]}`);
    value = (value << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out[idx++] = (value >> bits) & 0xff;
    }
  }
  return out;
}

function stripHexPrefix(hex: string): string {
  return hex.startsWith("0x") ? hex.slice(2) : hex;
}

export function encodeInvoiceQr(invoiceId: string): string {
  const bytes = fromHex(stripHexPrefix(invoiceId));
  if (bytes.length !== INVOICE_BYTES) {
    throw new Error(`invoiceId must be ${INVOICE_BYTES} bytes, got ${bytes.length}`);
  }
  return encodeBase32(bytes);
}

export function decodeInvoiceQr(qr: string): string | null {
  try {
    const bytes = decodeBase32(qr);
    if (bytes.length !== INVOICE_BYTES) return null;
    return "0x" + toHex(bytes);
  } catch {
    return null;
  }
}

export function encodeVoucherQr(voucherId: string, preimage: Uint8Array): string {
  if (preimage.length !== 32) {
    throw new Error(`preimage must be 32 bytes, got ${preimage.length}`);
  }
  const idBytes = fromHex(stripHexPrefix(voucherId));
  if (idBytes.length !== 32) {
    throw new Error(`voucherId must be 32 bytes, got ${idBytes.length}`);
  }
  const buf = new Uint8Array(VOUCHER_BYTES);
  buf.set(idBytes, 0);
  buf.set(preimage, 32);
  return encodeBase32(buf);
}

export function decodeVoucherQr(
  qr: string,
): { voucherId: string; preimage: Uint8Array } | null {
  try {
    const bytes = decodeBase32(qr);
    if (bytes.length !== VOUCHER_BYTES) return null;
    return {
      voucherId: "0x" + toHex(bytes.subarray(0, 32)),
      preimage: bytes.slice(32, 64),
    };
  } catch {
    return null;
  }
}
