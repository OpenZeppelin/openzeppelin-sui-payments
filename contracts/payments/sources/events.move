/// Event types and package-private emit helpers for the payments package.
///
/// All on-chain state transitions worth indexing emit one event from this
/// module. Indexers filter by event type (`InvoicePaid`, `VoucherRedeemed`, …)
/// and resolve the embedded IDs back to the relevant objects.
module openzeppelin_payments::events;

use sui::event;

// === Events ===

/// Emitted when a merchant issues a fresh `Invoice` via `payment::new`.
public struct InvoiceCreated has copy, drop {
    /// ID of the newly-shared `Invoice` object.
    invoice_id: ID,
}

/// Emitted when a customer creates a fresh `Voucher` via `redemption::new`.
public struct VoucherCreated has copy, drop {
    /// ID of the newly-shared `Voucher` object.
    voucher_id: ID,
}

/// Emitted when a customer settles an `Invoice`. Indexer resolves
/// `invoice_id`/`order_ref` → settled.
public struct InvoicePaid has copy, drop {
    /// ID of the settled `Invoice` (now destroyed).
    invoice_id: ID,
    /// Merchant-supplied order reference carried over from the invoice.
    order_ref: vector<u8>,
    /// Address that paid (and received the soulbound `Receipt<Payment>`).
    customer: address,
    /// Stablecoin amount settled.
    amount: u64,
    /// LOYALTY units minted to the customer.
    loyalty: u64,
    /// Settlement clock timestamp (ms since epoch).
    timestamp_ms: u64,
}

/// Emitted when a customer redeems a `Voucher`. Indexer resolves
/// `voucher_id` → redeemed.
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

/// Emitted when a merchant replaces its loyalty mint `Config`.
public struct ConfigUpdated has copy, drop {}

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
    amount: u64,
    loyalty: u64,
    timestamp_ms: u64,
) {
    event::emit(InvoicePaid {
        invoice_id,
        order_ref,
        customer,
        amount,
        loyalty,
        timestamp_ms,
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
public(package) fun emit_config_updated() {
    event::emit(ConfigUpdated {});
}
