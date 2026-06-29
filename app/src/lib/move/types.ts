/**
 * TypeScript shapes mirroring the on-chain Move structs we read. SuiClient
 * returns object contents as untyped JSON with bigints serialized as strings;
 * these types make destructuring + downstream rendering explicit and let the
 * compiler catch field renames after Move-side refactors.
 *
 * Object-model note: with the centralized `Merchant`, `Invoice`/`Voucher` and
 * `Receipt<Payment>`/`Receipt<Redemption>` are all `store`-only (no `UID`).
 * Each value is held under its issuance `ID` in a `Table<ID, V>` on the
 * merchant, and that table key is the externally-visible "id" (the QR value).
 * It is NOT a field on the struct - parsers don't try to read `id` from the
 * content fields.
 */

export type SuiAddress = string;
export type SuiObjectId = string;

// ---------------------------------------------------------------------------
// Merchant / Config
// ---------------------------------------------------------------------------

export interface Config {
  payoutAddress: SuiAddress;
  /** Fully-qualified TypeName, e.g. "0x..::stablecoin_mock::STABLECOIN_MOCK" */
  acceptedPaymentType: string;
  /** Decimals of the accepted stablecoin, snapshotted from `Currency<C>` at config-time. */
  paymentDecimals: number;
  /**
   * Raw u64 coefficient scaled by `LOYALTY_FLOAT_SCALING = 1e9`. Divide by it to
   * get the human decimal ("1.0" = 1 LOY per human unit). `0` disables minting.
   */
  loyaltyCoefficient: bigint;
  /** Hard cap on minted LOYALTY per payment. */
  maxLoyaltyPerPayment: bigint;
  invoiceTtlMs: bigint;
  voucherTtlMs: bigint;
}

/** Mirrors `LOYALTY_FLOAT_SCALING` in `config.move`. */
export const LOYALTY_FLOAT_SCALING = 1_000_000_000n;

export interface Merchant {
  id: SuiObjectId;
  name: string;
  logoUrl: string | null;
  config: Config;
  /** Parent object id of `Table<ID, Listing>` — query dynamic fields to enumerate. */
  listingsTableId: SuiObjectId;
  /** Parent of `Table<ID, ID>` mapping variant_id → listing_id. */
  variantIndexTableId: SuiObjectId;
  /** Parent of `Table<ID, Invoice>` — open invoices keyed by issuance id. */
  invoicesTableId: SuiObjectId;
  /** Parent of `Table<ID, Voucher>` — open vouchers keyed by issuance id. */
  vouchersTableId: SuiObjectId;
  /** Parent of `Table<ID, Receipt<Payment>>` — keyed by settled invoice id. */
  invoiceReceiptsTableId: SuiObjectId;
  /** Parent of `Table<ID, Receipt<Redemption>>` — keyed by redeemed voucher id. */
  voucherReceiptsTableId: SuiObjectId;
}

export function parseConfig(raw: any): Config {
  const f = raw.fields ?? raw;
  return {
    payoutAddress: f.payout_address,
    acceptedPaymentType: typeNameToString(f.accepted_payment_type),
    paymentDecimals: Number(f.payment_decimals),
    loyaltyCoefficient: BigInt(f.loyalty_coefficient),
    maxLoyaltyPerPayment: BigInt(f.max_loyalty_per_payment),
    invoiceTtlMs: BigInt(f.invoice_ttl_ms),
    voucherTtlMs: BigInt(f.voucher_ttl_ms),
  };
}

export function parseMerchant(content: any): Merchant {
  const f = content.fields;
  return {
    id: f.id.id,
    name: f.name,
    logoUrl: optionToValue<string>(f.logo_url),
    config: parseConfig(f.config),
    listingsTableId: f.listings.fields.id.id,
    variantIndexTableId: f.variant_index.fields.id.id,
    invoicesTableId: f.invoices.fields.id.id,
    vouchersTableId: f.vouchers.fields.id.id,
    invoiceReceiptsTableId: f.invoice_receipts.fields.id.id,
    voucherReceiptsTableId: f.voucher_receipts.fields.id.id,
  };
}

// ---------------------------------------------------------------------------
// Listing / Variant
// ---------------------------------------------------------------------------

export interface Variant {
  id: SuiObjectId;
  name: string;
  price: bigint;
  loyaltyPrice: bigint | null;
}

export interface Listing {
  id: SuiObjectId;
  name: string;
  active: boolean;
  variants: Variant[];
}

export function parseVariant(raw: any): Variant {
  const f = raw.fields ?? raw;
  return {
    id: f.id.id ?? f.id,
    name: f.name,
    price: BigInt(f.price),
    loyaltyPrice: optionToValueBig(f.loyalty_price),
  };
}

export function parseListing(content: any): Listing {
  const f = content.fields;
  // `VecMap<ID, Variant>` serializes as `{ contents: [{ key: ID, value: Variant }, ...] }`
  const entries = (f.variants?.fields?.contents ?? []) as Array<any>;
  const variants = entries.map((entry) => parseVariant(entry.fields.value));
  return {
    id: f.id.id ?? f.id,
    name: f.name,
    active: Boolean(f.active),
    variants,
  };
}

// ---------------------------------------------------------------------------
// Invoice / Voucher — `store`-only values stored in merchant tables.
// `id` comes from the table key (passed in by the caller), not the struct.
// ---------------------------------------------------------------------------

export interface Item {
  variantId: SuiObjectId;
  quantity: bigint;
  price: bigint;
}

export interface Invoice {
  id: SuiObjectId;
  payoutAddress: SuiAddress;
  paymentType: string;
  items: Item[];
  amount: bigint;
  loyalty: bigint;
  orderRef: number[];
  expiresAtMs: bigint;
}

export interface Voucher {
  id: SuiObjectId;
  customer: SuiAddress;
  items: Item[];
  amount: bigint;
  expiresAtMs: bigint;
  /**
   * blake2b256 commitment to the customer's redemption preimage. The cashier
   * UI can hash a scanned preimage and compare against this to sanity-check
   * before submitting the redeem tx; the chain enforces it regardless.
   */
  redeemHash: Uint8Array;
}

export function parseItem(raw: any): Item {
  const f = raw.fields ?? raw;
  return {
    variantId: f.variant_id,
    quantity: BigInt(f.quantity),
    price: BigInt(f.price),
  };
}

/**
 * `raw` is the value side of a `Table<ID, Invoice>` entry — i.e. the
 * `content.fields.value.fields` returned by `getDynamicFieldObject`. The
 * outer `id` is the table key, supplied separately.
 */
export function parseInvoice(id: SuiObjectId, raw: any): Invoice {
  const f = raw.fields ?? raw;
  return {
    id,
    payoutAddress: f.payout_address,
    paymentType: typeNameToString(f.payment_type),
    items: (f.items as any[]).map(parseItem),
    amount: BigInt(f.amount),
    loyalty: BigInt(f.loyalty),
    orderRef: f.order_ref as number[],
    expiresAtMs: BigInt(f.expires_at_ms),
  };
}

export function parseVoucher(id: SuiObjectId, raw: any): Voucher {
  const f = raw.fields ?? raw;
  return {
    id,
    customer: f.customer,
    items: (f.items as any[]).map(parseItem),
    // `funds` is a `Balance<LOYALTY>`. Sui's normalized-JSON encoding for
    // Balance differs between framework versions: newer emits just the u64
    // value as a string (`"funds": "5"`), older nests it as
    // `{ fields: { value: "5" } }`. Same shape-versioning issue as
    // `optionToValue` — handle both.
    amount: balanceToValue(f.funds),
    expiresAtMs: BigInt(f.expires_at_ms),
    redeemHash: bytesFromVectorU8(f.redeem_hash),
  };
}

// ---------------------------------------------------------------------------
// Receipts — `store`-only values stored in merchant.invoice_receipts /
// .voucher_receipts. Keyed by the originating invoice/voucher id; the new
// model puts the settling `customer` directly on the receipt (no longer
// soulbound by transfer to an address).
// ---------------------------------------------------------------------------

export interface PaymentReceipt {
  /** Key in `invoice_receipts` — also the settled invoice's id. */
  invoiceId: SuiObjectId;
  customer: SuiAddress;
  payoutAddress: SuiAddress;
  paymentType: string;
  items: Item[];
  amount: bigint;
  loyalty: bigint;
  orderRef: number[];
  timestampMs: bigint;
}

export interface RedemptionReceipt {
  /** Key in `voucher_receipts` — also the redeemed voucher's id. */
  voucherId: SuiObjectId;
  customer: SuiAddress;
  items: Item[];
  amount: bigint;
  timestampMs: bigint;
}

export function parsePaymentReceipt(invoiceId: SuiObjectId, raw: any): PaymentReceipt {
  const f = raw.fields ?? raw;
  const d = f.data.fields;
  return {
    invoiceId,
    customer: f.customer,
    payoutAddress: d.payout_address,
    paymentType: typeNameToString(d.payment_type),
    items: (f.items as any[]).map(parseItem),
    amount: BigInt(f.amount),
    loyalty: BigInt(d.loyalty),
    orderRef: d.order_ref as number[],
    timestampMs: BigInt(f.timestamp_ms),
  };
}

export function parseRedemptionReceipt(voucherId: SuiObjectId, raw: any): RedemptionReceipt {
  const f = raw.fields ?? raw;
  // The `data: Redemption` payload only holds `voucher_id`, which we already
  // pass in as the parameter (it's the table key) — nothing else to read here.
  return {
    voucherId,
    customer: f.customer,
    items: (f.items as any[]).map(parseItem),
    amount: BigInt(f.amount),
    timestampMs: BigInt(f.timestamp_ms),
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Sui's normalized-JSON encoding for `Option<T>` differs between framework /
 * SDK versions:
 *
 *   - Newer: the inner value directly, or `null` for `None`
 *     (e.g. `"loyalty_price": "50"` or `"loyalty_price": null`)
 *   - Older: `{ vec: [] | [value] }` (sometimes wrapped in `{ fields: ... }`)
 *
 * Both forms appear in the wild — handle both so the same parsers work
 * regardless of which RPC / SDK version returns the object.
 */
function optionToValue<T>(raw: any): T | null {
  if (raw === null || raw === undefined) return null;
  // Newer SDK: primitive value sitting directly under the Option's field name.
  if (typeof raw !== "object") return raw as T;
  // Older SDK: `{ vec: [...] }` possibly wrapped in `{ fields: { vec: [...] } }`.
  const vec = (raw.fields?.vec ?? raw.vec) as T[] | undefined;
  if (!vec || vec.length === 0) return null;
  return vec[0];
}

function optionToValueBig(raw: any): bigint | null {
  const v = optionToValue<string | number | bigint>(raw);
  return v === null ? null : BigInt(v as any);
}

/**
 * Reads the u64 inside a `Balance<T>`. Same dual-shape support as
 * `optionToValue`: newer Sui SDK flattens to just the value
 * (`"funds": "5"`), older nests it as `{ fields: { value: "5" } }`.
 */
function balanceToValue(raw: any): bigint {
  if (raw === null || raw === undefined) return 0n;
  if (typeof raw !== "object") return BigInt(raw);
  return BigInt(raw.fields?.value ?? raw.value ?? 0);
}

/**
 * Normalizes a Move `vector<u8>` field value to a `Uint8Array`. Sui's
 * normalized JSON usually emits these as `number[]`, but older SDKs and
 * some response paths return a hex-encoded `string`. Handle both so the
 * parser doesn't break across framework versions.
 */
function bytesFromVectorU8(raw: any): Uint8Array {
  if (raw === null || raw === undefined) return new Uint8Array(0);
  if (raw instanceof Uint8Array) return raw;
  if (Array.isArray(raw)) return Uint8Array.from(raw as number[]);
  if (typeof raw === "string") {
    const clean = raw.startsWith("0x") ? raw.slice(2) : raw;
    if (clean.length % 2 !== 0) return new Uint8Array(0);
    const out = new Uint8Array(clean.length / 2);
    for (let i = 0; i < out.length; i++) {
      out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
    }
    return out;
  }
  return new Uint8Array(0);
}

/** `TypeName` serializes as `{ name: "0x..::module::Type" }`. */
function typeNameToString(raw: any): string {
  return (raw?.fields?.name ?? raw?.name ?? "") as string;
}

export function utf8FromBytes(bytes: number[]): string {
  return new TextDecoder().decode(new Uint8Array(bytes));
}
