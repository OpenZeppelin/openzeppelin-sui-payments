/// Event types and package-private emit helpers for the payments package.
///
/// All on-chain state transitions worth indexing emit one event from this
/// module. Indexers filter by event type (`InvoicePaid`, `VoucherRedeemed`, ...).
/// Note the embedded identifiers are keys for store-only values owned by the
/// merchant. `Invoice`, `Voucher`, and `Listing` entries are `Table` keys.
/// A `Variant` is keyed inside its parent listing. These are not standalone Sui
/// object IDs, so they cannot be resolved via object lookup.
module openzeppelin_payments::events;

use openzeppelin_payments::config::Config;
use std::string::String;
use std::type_name::TypeName;
use sui::event;

// === Events ===

/// Emitted when a merchant issues a fresh `Invoice` via `merchant::create_invoice`.
public struct InvoiceCreated has copy, drop {
    /// Issuance identifier keying the new store-only `Invoice` in
    /// `Merchant.invoices` (not a standalone Sui object ID).
    invoice_id: ID,
}

/// Emitted when a customer creates a fresh `Voucher` via `merchant::create_voucher`.
public struct VoucherCreated has copy, drop {
    /// Issuance identifier keying the new store-only `Voucher` in
    /// `Merchant.vouchers` (not a standalone Sui object ID).
    voucher_id: ID,
}

/// Emitted when a customer settles an `Invoice`. Indexer resolves
/// `invoice_id`/`order_ref` -> settled.
///
/// Carries `payout_address` + `payment_type` (mirroring `InvoiceCanceled`) so
/// the historical payout/currency survives `prune_invoice_receipts`. The
/// Receipt's `items` line-item breakdown is NOT mirrored here and is lost on
/// prune - off-chain indexers needing it must capture it beforehand.
public struct InvoicePaid has copy, drop {
    /// ID of the settled `Invoice` (now destroyed).
    invoice_id: ID,
    /// Merchant-supplied order reference carried over from the invoice.
    order_ref: vector<u8>,
    /// Address that paid (recorded as `customer` on the stored `Receipt`).
    customer: address,
    /// Payout address recorded on the invoice at issuance (snapshotted from
    /// `Config.payout_address`).
    payout_address: address,
    /// `TypeName` of the stablecoin the invoice was settled in.
    payment_type: TypeName,
    /// Stablecoin amount settled.
    amount: u64,
    /// LOYALTY units minted to the customer.
    loyalty: u64,
    /// Settlement clock timestamp (ms since epoch).
    timestamp_ms: u64,
    /// Custody discriminator: `true` if settled via the open-loop `merchant::pay_with_coin`,
    /// `false` if via the PAS `merchant::pay`.
    paid_with_coin: bool,
}

/// Emitted when a customer redeems a `Voucher`. Indexer resolves
/// `voucher_id` -> redeemed.
public struct VoucherRedeemed has copy, drop {
    /// ID of the redeemed `Voucher` (now destroyed).
    voucher_id: ID,
    /// Address that originally locked the LOYALTY balance.
    customer: address,
    /// LOYALTY units burned.
    amount: u64,
    /// Settlement clock timestamp (ms since epoch).
    timestamp_ms: u64,
}

/// Emitted when an `Invoice` is canceled - either an expired invoice cleaned up
/// via the permissionless `merchant::cancel_expired_invoice`, or an open invoice
/// invalidated early by a `MerchantRole` holder via `merchant::cancel_invoice`.
public struct InvoiceCanceled has copy, drop {
    /// ID of the canceled `Invoice` (now destroyed).
    invoice_id: ID,
    /// Payout address recorded on the canceled invoice.
    payout_address: address,
    /// `TypeName` of the stablecoin the canceled invoice expected.
    payment_type: TypeName,
    /// Stablecoin amount that was due on the canceled invoice.
    amount: u64,
    /// Merchant-supplied order reference carried over from the invoice.
    order_ref: vector<u8>,
}

/// Emitted when a `Voucher` is canceled - either an expired voucher cleaned up
/// via the permissionless `merchant::cancel_expired_voucher`, or an open voucher
/// invalidated early by a `MerchantRole` holder via `merchant::cancel_voucher`.
/// In both cases the locked LOYALTY balance has been returned to `customer`.
public struct VoucherCanceled has copy, drop {
    /// ID of the canceled `Voucher` (now destroyed).
    voucher_id: ID,
    /// Address that received the returned LOYALTY balance.
    customer: address,
    /// LOYALTY units returned.
    amount: u64,
}

/// Emitted when a merchant adds a `Listing`.
public struct ListingAdded has copy, drop {
    /// ID of the added listing.
    listing_id: ID,
}

/// Emitted when a merchant removes a `Listing`.
public struct ListingRemoved has copy, drop {
    /// ID of the removed listing.
    listing_id: ID,
}

/// Emitted when a merchant toggles a listing's `active` flag.
public struct ListingStatusChanged has copy, drop {
    /// ID of the affected listing.
    listing_id: ID,
    /// New active state.
    active: bool,
}

/// Emitted when a merchant adds a `Variant` to a listing.
public struct VariantAdded has copy, drop {
    /// ID of the parent listing.
    listing_id: ID,
    /// ID of the new variant.
    variant_id: ID,
}

/// Emitted when a merchant removes a `Variant` from a listing.
public struct VariantRemoved has copy, drop {
    /// ID of the parent listing.
    listing_id: ID,
    /// ID of the removed variant.
    variant_id: ID,
}

/// Emitted when a merchant replaces its `Config` (which now subsumes payout
/// address and accepted payment type). Carries the full new config values.
public struct ConfigUpdated has copy, drop {
    /// The full replacement config.
    config: Config,
}

/// Emitted when a merchant updates its display name or logo. Carries the new
/// display values.
public struct DisplayUpdated has copy, drop {
    /// New display name.
    name: String,
    /// New optional logo URL.
    logo_url: Option<String>,
}

// === Package Functions ===

/// Emit `InvoiceCreated`.
public(package) fun emit_invoice_created(invoice_id: ID) {
    event::emit(InvoiceCreated { invoice_id });
}

/// Emit `VoucherCreated`.
public(package) fun emit_voucher_created(voucher_id: ID) {
    event::emit(VoucherCreated { voucher_id });
}

/// Emit `InvoicePaid`.
public(package) fun emit_invoice_paid(
    invoice_id: ID,
    order_ref: vector<u8>,
    customer: address,
    payout_address: address,
    payment_type: TypeName,
    amount: u64,
    loyalty: u64,
    timestamp_ms: u64,
    paid_with_coin: bool,
) {
    event::emit(InvoicePaid {
        invoice_id,
        order_ref,
        customer,
        payout_address,
        payment_type,
        amount,
        loyalty,
        timestamp_ms,
        paid_with_coin,
    });
}

/// Emit `VoucherRedeemed`.
public(package) fun emit_voucher_redeemed(
    voucher_id: ID,
    customer: address,
    amount: u64,
    timestamp_ms: u64,
) {
    event::emit(VoucherRedeemed {
        voucher_id,
        customer,
        amount,
        timestamp_ms,
    });
}

/// Emit `InvoiceCanceled`.
public(package) fun emit_invoice_canceled(
    invoice_id: ID,
    payout_address: address,
    payment_type: TypeName,
    amount: u64,
    order_ref: vector<u8>,
) {
    event::emit(InvoiceCanceled { invoice_id, payout_address, payment_type, amount, order_ref });
}

/// Emit `VoucherCanceled`.
public(package) fun emit_voucher_canceled(voucher_id: ID, customer: address, amount: u64) {
    event::emit(VoucherCanceled { voucher_id, customer, amount });
}

/// Emit `ListingAdded`.
public(package) fun emit_listing_added(listing_id: ID) {
    event::emit(ListingAdded { listing_id });
}

/// Emit `ListingRemoved`.
public(package) fun emit_listing_removed(listing_id: ID) {
    event::emit(ListingRemoved { listing_id });
}

/// Emit `ListingStatusChanged`.
public(package) fun emit_listing_status_changed(listing_id: ID, active: bool) {
    event::emit(ListingStatusChanged { listing_id, active });
}

/// Emit `VariantAdded`.
public(package) fun emit_variant_added(listing_id: ID, variant_id: ID) {
    event::emit(VariantAdded { listing_id, variant_id });
}

/// Emit `VariantRemoved`.
public(package) fun emit_variant_removed(listing_id: ID, variant_id: ID) {
    event::emit(VariantRemoved { listing_id, variant_id });
}

/// Emit `ConfigUpdated`.
public(package) fun emit_config_updated(config: Config) {
    event::emit(ConfigUpdated { config });
}

/// Emit `DisplayUpdated`.
public(package) fun emit_display_updated(name: String, logo_url: Option<String>) {
    event::emit(DisplayUpdated { name, logo_url });
}

// === Test-Only Helpers ===

#[test_only]
public fun invoice_paid(
    invoice_id: ID,
    order_ref: vector<u8>,
    customer: address,
    payout_address: address,
    payment_type: TypeName,
    amount: u64,
    loyalty: u64,
    timestamp_ms: u64,
    paid_with_coin: bool,
): InvoicePaid {
    InvoicePaid {
        invoice_id,
        order_ref,
        customer,
        payout_address,
        payment_type,
        amount,
        loyalty,
        timestamp_ms,
        paid_with_coin,
    }
}

#[test_only]
public fun voucher_redeemed(
    voucher_id: ID,
    customer: address,
    amount: u64,
    timestamp_ms: u64,
): VoucherRedeemed {
    VoucherRedeemed { voucher_id, customer, amount, timestamp_ms }
}

#[test_only]
public fun invoice_canceled(
    invoice_id: ID,
    payout_address: address,
    payment_type: TypeName,
    amount: u64,
    order_ref: vector<u8>,
): InvoiceCanceled {
    InvoiceCanceled { invoice_id, payout_address, payment_type, amount, order_ref }
}

#[test_only]
public fun voucher_canceled(voucher_id: ID, customer: address, amount: u64): VoucherCanceled {
    VoucherCanceled { voucher_id, customer, amount }
}

#[test_only]
public fun invoice_created(invoice_id: ID): InvoiceCreated {
    InvoiceCreated { invoice_id }
}

#[test_only]
public fun voucher_created(voucher_id: ID): VoucherCreated {
    VoucherCreated { voucher_id }
}

#[test_only]
public fun listing_added(listing_id: ID): ListingAdded {
    ListingAdded { listing_id }
}

#[test_only]
public fun listing_removed(listing_id: ID): ListingRemoved {
    ListingRemoved { listing_id }
}

#[test_only]
public fun listing_status_changed(listing_id: ID, active: bool): ListingStatusChanged {
    ListingStatusChanged { listing_id, active }
}

#[test_only]
public fun variant_added(listing_id: ID, variant_id: ID): VariantAdded {
    VariantAdded { listing_id, variant_id }
}

#[test_only]
public fun variant_removed(listing_id: ID, variant_id: ID): VariantRemoved {
    VariantRemoved { listing_id, variant_id }
}

#[test_only]
public fun config_updated(config: Config): ConfigUpdated {
    ConfigUpdated { config }
}

#[test_only]
public fun display_updated(name: String, logo_url: Option<String>): DisplayUpdated {
    DisplayUpdated { name, logo_url }
}
