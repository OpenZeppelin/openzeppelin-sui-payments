/// Event types and package-private emit helpers for the payments package.
///
/// All on-chain state transitions worth indexing emit one event from this
/// module. Indexers filter by event type (`InvoicePaid`, `VoucherRedeemed`, …)
/// and resolve the embedded IDs back to the relevant objects.
module openzeppelin_payments::events;

use sui::event;

// TODO#q: remove merchant_id from events (the only one merchant available)

// === Events ===

/// Emitted when a merchant issues a fresh `Invoice` via `payment::new`.
public struct InvoiceCreated has copy, drop {
    invoice_id: ID,
}

/// Emitted when a customer creates a fresh `Voucher` via `redemption::new`.
public struct VoucherCreated has copy, drop {
    voucher_id: ID,
}

/// Emitted when a customer settles an `Invoice`. Indexer subscribes filtered by
/// `merchant_id` and resolves `invoice_id`/`order_ref` → settled.
public struct InvoicePaid has copy, drop {
    invoice_id: ID,
    merchant_id: ID,
    order_ref: vector<u8>,
    customer: address,
    amount: u64,
    loyalty: u64,
    timestamp_ms: u64,
}

/// Emitted when a customer redeems a `Voucher`. Indexer subscribes filtered
/// by `merchant_id` and resolves `voucher_id` → redeemed.
public struct VoucherRedeemed has copy, drop {
    voucher_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
    timestamp_ms: u64,
}

/// Emitted when a merchant adds a `Listing`.
public struct ListingAdded has copy, drop {
    merchant_id: ID,
    listing_id: ID,
}

/// Emitted when a merchant removes a `Listing`.
public struct ListingRemoved has copy, drop {
    merchant_id: ID,
    listing_id: ID,
}

/// Emitted when a merchant toggles a listing's `active` flag.
public struct ListingStatusChanged has copy, drop {
    merchant_id: ID,
    listing_id: ID,
    active: bool,
}

/// Emitted when a merchant adds a `Variant` to a listing.
public struct VariantAdded has copy, drop {
    merchant_id: ID,
    listing_id: ID,
    variant_id: ID,
}

/// Emitted when a merchant removes a `Variant` from a listing.
public struct VariantRemoved has copy, drop {
    merchant_id: ID,
    listing_id: ID,
    variant_id: ID,
}

/// Emitted when a merchant replaces its loyalty mint `Config`.
public struct ConfigUpdated has copy, drop {
    merchant_id: ID,
}

// === Package Functions ===
//
// Thin wrappers around `event::emit`. Other modules in this package call these
// rather than constructing event structs directly so the struct fields can stay
// private to `events.move`.

public(package) fun emit_invoice_created(invoice_id: ID) {
    event::emit(InvoiceCreated { invoice_id });
}

public(package) fun emit_voucher_created(voucher_id: ID) {
    event::emit(VoucherCreated { voucher_id });
}

public(package) fun emit_invoice_paid(
    invoice_id: ID,
    merchant_id: ID,
    order_ref: vector<u8>,
    customer: address,
    amount: u64,
    loyalty: u64,
    timestamp_ms: u64,
) {
    event::emit(InvoicePaid {
        invoice_id,
        merchant_id,
        order_ref,
        customer,
        amount,
        loyalty,
        timestamp_ms,
    });
}

public(package) fun emit_voucher_redeemed(
    voucher_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
    timestamp_ms: u64,
) {
    event::emit(VoucherRedeemed {
        voucher_id,
        merchant_id,
        customer,
        amount,
        timestamp_ms,
    });
}

public(package) fun emit_listing_added(merchant_id: ID, listing_id: ID) {
    event::emit(ListingAdded { merchant_id, listing_id });
}

public(package) fun emit_listing_removed(merchant_id: ID, listing_id: ID) {
    event::emit(ListingRemoved { merchant_id, listing_id });
}

public(package) fun emit_listing_status_changed(merchant_id: ID, listing_id: ID, active: bool) {
    event::emit(ListingStatusChanged { merchant_id, listing_id, active });
}

public(package) fun emit_variant_added(merchant_id: ID, listing_id: ID, variant_id: ID) {
    event::emit(VariantAdded { merchant_id, listing_id, variant_id });
}

public(package) fun emit_variant_removed(merchant_id: ID, listing_id: ID, variant_id: ID) {
    event::emit(VariantRemoved { merchant_id, listing_id, variant_id });
}

public(package) fun emit_config_updated(merchant_id: ID) {
    event::emit(ConfigUpdated {
        merchant_id,
    });
}
