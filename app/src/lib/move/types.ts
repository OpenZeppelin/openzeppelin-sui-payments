/**
 * TypeScript shapes mirroring the on-chain Move structs we read. SuiClient
 * returns object contents as untyped JSON with bigints serialized as strings;
 * these types make destructuring + downstream rendering explicit and let the
 * compiler catch field renames after Move-side refactors.
 *
 * Each type has a `parse*` helper next to it that accepts the raw `content.fields`
 * shape from `SuiClient.getObject({ ...options: { showContent: true } })`.
 */

export type SuiAddress = string;
export type SuiObjectId = string;

// ---------------------------------------------------------------------------
// Merchant / Config
// ---------------------------------------------------------------------------

export interface Config {
  mintNumerator: bigint;
  mintDenominator: bigint;
  maxMintPerPayment: bigint;
  invoiceTtlMs: bigint;
  voucherTtlMs: bigint;
}

export interface Merchant {
  id: SuiObjectId;
  name: string;
  logoUrl: string | null;
  payoutAddress: SuiAddress;
  acceptedPaymentType: string; // fully-qualified TypeName, e.g. "0x..::stablecoin_mock::STABLECOIN_MOCK"
  config: Config;
  /** Parent object id of the `Table<ID, Listing>` — query dynamic fields under this id to enumerate listings. */
  listingsTableId: SuiObjectId;
  /** Parent of `Table<ID, ID>` mapping variant_id → listing_id. */
  variantIndexTableId: SuiObjectId;
}

export function parseConfig(raw: any): Config {
  const f = raw.fields ?? raw;
  return {
    mintNumerator: BigInt(f.mint_numerator),
    mintDenominator: BigInt(f.mint_denominator),
    maxMintPerPayment: BigInt(f.max_mint_per_payment),
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
    payoutAddress: f.payout_address,
    acceptedPaymentType: typeNameToString(f.accepted_payment_type),
    config: parseConfig(f.config),
    listingsTableId: f.listings.fields.id.id,
    variantIndexTableId: f.variant_index.fields.id.id,
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
    loyaltyPrice: optionToValue<string>(f.loyalty_price)?.then ? null : optionToValueBig(f.loyalty_price),
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
// Invoice / Voucher
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
}

export function parseItem(raw: any): Item {
  const f = raw.fields ?? raw;
  return {
    variantId: f.variant_id,
    quantity: BigInt(f.quantity),
    price: BigInt(f.price),
  };
}

export function parseInvoice(content: any): Invoice {
  const f = content.fields;
  return {
    id: f.id.id,
    payoutAddress: f.payout_address,
    paymentType: typeNameToString(f.payment_type),
    items: (f.items as any[]).map(parseItem),
    amount: BigInt(f.amount),
    loyalty: BigInt(f.loyalty),
    orderRef: f.order_ref as number[],
    expiresAtMs: BigInt(f.expires_at_ms),
  };
}

export function parseVoucher(content: any): Voucher {
  const f = content.fields;
  return {
    id: f.id.id,
    customer: f.customer,
    items: (f.items as any[]).map(parseItem),
    // `funds` is a Balance<LOYALTY>; its `value` field carries the amount.
    amount: BigInt(f.funds.fields?.value ?? f.funds.value ?? 0),
    expiresAtMs: BigInt(f.expires_at_ms),
  };
}

// ---------------------------------------------------------------------------
// Receipts
// ---------------------------------------------------------------------------

export interface PaymentReceipt {
  id: SuiObjectId;
  invoiceId: SuiObjectId;
  payoutAddress: SuiAddress;
  paymentType: string;
  items: Item[];
  amount: bigint;
  loyalty: bigint;
  orderRef: number[];
  timestampMs: bigint;
}

export interface RedemptionReceipt {
  id: SuiObjectId;
  voucherId: SuiObjectId;
  items: Item[];
  amount: bigint;
  timestampMs: bigint;
}

export function parsePaymentReceipt(content: any): PaymentReceipt {
  const f = content.fields;
  const d = f.data.fields;
  return {
    id: f.id.id,
    invoiceId: d.invoice_id,
    payoutAddress: d.payout_address,
    paymentType: typeNameToString(d.payment_type),
    items: (f.items as any[]).map(parseItem),
    amount: BigInt(f.amount),
    loyalty: BigInt(d.loyalty),
    orderRef: d.order_ref as number[],
    timestampMs: BigInt(f.timestamp_ms),
  };
}

export function parseRedemptionReceipt(content: any): RedemptionReceipt {
  const f = content.fields;
  const d = f.data.fields;
  return {
    id: f.id.id,
    voucherId: d.voucher_id,
    items: (f.items as any[]).map(parseItem),
    amount: BigInt(f.amount),
    timestampMs: BigInt(f.timestamp_ms),
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Sui SDK encodes `Option<T>` as `{ vec: [] | [value] }`. Returns the
 * inner value or null.
 */
function optionToValue<T>(raw: any): T | null {
  if (raw === null || raw === undefined) return null;
  const vec = (raw.fields?.vec ?? raw.vec) as T[] | undefined;
  if (!vec || vec.length === 0) return null;
  return vec[0];
}

function optionToValueBig(raw: any): bigint | null {
  const v = optionToValue<string | number | bigint>(raw);
  return v === null ? null : BigInt(v as any);
}

/** `TypeName` serializes as `{ name: "0x..::module::Type" }`. */
function typeNameToString(raw: any): string {
  return (raw?.fields?.name ?? raw?.name ?? "") as string;
}

export function utf8FromBytes(bytes: number[]): string {
  return new TextDecoder().decode(new Uint8Array(bytes));
}
