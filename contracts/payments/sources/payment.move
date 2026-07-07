/// Invoice - merchant-issued payment intent, stored as a value in `Merchant`.
///
/// This module only defines the `Invoice` data type plus a merchant-agnostic
/// constructor (`new`) and destructurer (`unpack`). It deliberately has NO
/// dependency on `merchant`: since `Merchant` stores `Table<ID, Invoice>` (so
/// `merchant` depends on `payment`), the reverse dependency would form an
/// illegal cycle. All merchant-aware logic - catalog pricing, issuance,
/// settlement (`pay`), and cancellation - therefore lives in `merchant`.
module openzeppelin_payments::payment;

use openzeppelin_payments::receipt::Item;
use std::type_name::TypeName;

// === Structs ===

/// Merchant-issued invoice. Stored in `Merchant.invoices` keyed by a freshly
/// minted ID; that ID is surfaced via QR for the customer to scan and settle.
///
/// **Snapshot semantics.** Every settlement-relevant field below
/// (`payout_address`, `payment_type`, item prices, `amount`, `loyalty`) is
/// captured from the live `Merchant.config` at issuance and is **immutable** for
/// the invoice's lifetime, so a later `merchant::update_config` only affects
/// *future* invoices. While open, the invoice is thus a binding commitment: the
/// customer settles at exactly these terms. Its continued *existence* is not
/// guaranteed, though - it settles against the snapshot until it either expires
/// (then anyone can clean it up via `cancel_invoice`) or a `MerchantRole` holder
/// voids it early via `merchant::force_cancel_invoice` (the escape hatch for a
/// mis-issued invoice).
///
/// `store`-only (no `key`): identity is the `Table` key, not an object UID.
public struct Invoice has store {
    /// Snapshot of `Config.payout_address` at issuance. The on-chain account
    /// that customer stablecoin actually routes to on `pay` - not a label or
    /// alias. Pinned for the invoice's lifetime; later config rotations don't
    /// retro-route already-issued invoices.
    payout_address: address,
    /// Snapshot of `Config.accepted_payment_type` at issuance. `merchant::pay<C>`
    /// aborts if `C` does not match this, preventing settlement in self-minted
    /// currencies.
    payment_type: TypeName,
    /// Line items with snapshot prices (stablecoin units).
    items: vector<Item>,
    /// Total stablecoin amount due, computed from `items` at issuance.
    amount: u64,
    /// Loyalty units the customer earns on settlement, snapshotted from the
    /// merchant's `Config` at issuance.
    loyalty: u64,
    /// Merchant-supplied opaque tag (e.g. POS order number).
    order_ref: vector<u8>,
    /// Expiry timestamp (ms). Past this point `pay` aborts and `cancel`
    /// becomes permissionless.
    expires_at_ms: u64,
}

// === Package Functions ===

/// Merchant-agnostic constructor. `merchant::create_invoice` resolves prices and
/// snapshots fields, then calls this.
public(package) fun new(
    payout_address: address,
    payment_type: TypeName,
    items: vector<Item>,
    amount: u64,
    loyalty: u64,
    order_ref: vector<u8>,
    expires_at_ms: u64,
): Invoice {
    Invoice { payout_address, payment_type, items, amount, loyalty, order_ref, expires_at_ms }
}

/// Consume the invoice and return its fields. `Invoice` has no `drop`, so
/// `merchant` destructures it through this on `pay` / `cancel`.
public(package) fun unpack(
    self: Invoice,
): (address, TypeName, vector<Item>, u64, u64, vector<u8>, u64) {
    let Invoice { payout_address, payment_type, items, amount, loyalty, order_ref, expires_at_ms } =
        self;
    (payout_address, payment_type, items, amount, loyalty, order_ref, expires_at_ms)
}

// === View Functions ===

/// Address that will receive the customer's stablecoin on `pay`.
public fun payout_address(self: &Invoice): address { self.payout_address }

/// `TypeName` of the stablecoin the customer must pay in.
public fun payment_type(self: &Invoice): TypeName { self.payment_type }

/// Line items, each carrying `variant_id`, `quantity`, and snapshot `price`.
public fun items(self: &Invoice): &vector<Item> { &self.items }

/// Total stablecoin due, computed from `items` at issuance.
public fun amount(self: &Invoice): u64 { self.amount }

/// Loyalty units that will be minted to the customer on settlement.
public fun loyalty(self: &Invoice): u64 { self.loyalty }

/// Merchant-supplied order reference (opaque bytes).
public fun order_ref(self: &Invoice): &vector<u8> { &self.order_ref }

/// Expiry timestamp (ms).
public fun expires_at_ms(self: &Invoice): u64 { self.expires_at_ms }
