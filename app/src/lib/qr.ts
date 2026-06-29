import { base32nopad } from "@scure/base";
import { fromHex, toHex } from "@mysten/sui/utils";

/**
 * QR payload codecs for invoice and voucher flows.
 *
 * Both payloads are raw bytes encoded as RFC 4648 base32 without padding via
 * `@scure/base`'s `base32nopad`. base32's alphabet (`A-Z`, `2-7`) falls
 * entirely inside QR's alphanumeric character set, so the QR library encodes
 * the payload at 5.5 bits/char instead of the 8 bits/char that byte mode would
 * use — about 30 % fewer scan bits than base64 for the same number of bytes.
 *
 *   - Invoice: 32-byte Sui ObjectId          → 52 chars
 *   - Voucher: 32-byte id ‖ 32-byte preimage → 103 chars
 *
 * Length disambiguates the two payloads if a caller ever needs to.
 */

const INVOICE_BYTES = 32;
const VOUCHER_BYTES = 64;

function stripHexPrefix(hex: string): string {
  return hex.startsWith("0x") ? hex.slice(2) : hex;
}

/** Tolerate scanner output that uses lowercase — base32 is case-insensitive. */
function decodeBase32(qr: string): Uint8Array {
  return base32nopad.decode(qr.trim().toUpperCase());
}

export function encodeInvoiceQr(invoiceId: string): string {
  const bytes = fromHex(stripHexPrefix(invoiceId));
  if (bytes.length !== INVOICE_BYTES) {
    throw new Error(`invoiceId must be ${INVOICE_BYTES} bytes, got ${bytes.length}`);
  }
  return base32nopad.encode(bytes);
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
  return base32nopad.encode(buf);
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
