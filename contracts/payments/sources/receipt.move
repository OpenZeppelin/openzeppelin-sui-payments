/// Receipts — soulbound on-chain proof of settlement.
///
/// `Receipt<Payment>` is minted at the end of `payment::pay<S>` and transferred
/// to the paying customer. `Receipt<Redemption>` is minted at the end of
/// `redemption::redeem` and transferred to the voucher's customer. Both are
/// `key`-only (no `store`), so they cannot be re-transferred or wrapped in
/// other structs — possession by an address is the proof, and that address
/// keeps the receipt forever.
///
/// This module also hosts the shared `Item` line type and the helpers
/// `new_item` and `compute_total`, which are reused by both `payment` and
/// `redemption` when building their respective line lists.
module openzeppelin_payments::receipt;

use openzeppelin_payments::merchant::Merchant;
use std::type_name::TypeName;

// === Errors ===

#[error(code = 0)]
const EZeroQuantity: vector<u8> = "Item quantity must be greater than zero";
#[error(code = 1)]
const EAmountOverflow: vector<u8> = "Amount exceeds u64 range";
#[error(code = 2)]
const ENoLoyaltyPrice: vector<u8> = "Variant is not redeemable: loyalty_price is not set";

// === Structs ===

/// One line on an `Invoice` or a `Voucher` — a quantity of a specific listing
/// variant at a snapshotted unit price. The price is in stablecoin units for
/// invoices and `LOYALTY` units for vouchers; the type is the same so it can
/// be reused across both flows. Snapshot pricing decouples the order from
/// later mutations of the underlying `Variant`.
public struct Item has drop, store {
    /// ID of the listing variant this line refers to.
    variant_id: ID,
    /// Quantity ordered.
    quantity: u64,
    /// Snapshot unit price (stablecoin units for invoices, LOYALTY units for vouchers).
    price: u64,
}

/// Soulbound proof of settlement. `T` is the flow-specific payload type:
/// `Payment` for invoice settlements, `Redemption` for voucher burns. The
/// generic shape lets the package add new receipt kinds later without
/// duplicating the shared fields.
public struct Receipt<T> has key {
    /// Object ID. The receipt itself is transferred to the customer.
    id: UID,
    /// Line items copied from the originating invoice or voucher.
    items: vector<Item>,
    /// Total settled amount (stablecoin for payment, LOYALTY for redemption).
    amount: u64,
    /// Settlement clock timestamp (ms since epoch).
    timestamp_ms: u64,
    /// Flow-specific payload (`Payment` or `Redemption`).
    data: T,
}

/// Payment-flow payload (carried inside `Receipt<Payment>`).
public struct Payment has drop, store {
    /// ID of the `Invoice` this receipt settled.
    invoice_id: ID,
    /// Payout address that received the stablecoin.
    payout_address: address,
    /// `TypeName` of the stablecoin the customer paid in (matches
    /// `Merchant.accepted_payment_type` and `Invoice.payment_type` at settlement).
    payment_type: TypeName,
    /// LOYALTY units minted to the customer on settlement.
    loyalty: u64,
    /// Merchant-supplied order reference carried over from the invoice.
    order_ref: vector<u8>,
}

/// Redemption-flow payload (carried inside `Receipt<Redemption>`).
public struct Redemption has drop, store {
    /// ID of the `Voucher` this receipt settled.
    voucher_id: ID,
}

// === Public Functions ===

/// Voluntarily discard a receipt. Only the owner (the customer the receipt was
/// transferred to) can call this since the receipt is `key`-only and owned.
/// The canonical settlement record stays on-chain as the originating
/// `InvoicePaid` / `VoucherRedeemed` event — destroying the receipt just
/// reclaims object storage for the customer.
public fun destroy<T: store + drop>(receipt: Receipt<T>) {
    let Receipt { id, items: _, amount: _, timestamp_ms: _, data: _ } = receipt;
    id.delete();
}

// === View Functions ===

/// ID of the listing variant this line refers to.
public fun variant_id(self: &Item): ID { self.variant_id }

/// Quantity ordered.
public fun quantity(self: &Item): u64 { self.quantity }

/// Snapshot unit price (stablecoin units for invoices, LOYALTY units for vouchers).
public fun price(self: &Item): u64 { self.price }

/// Object ID of the receipt.
public fun id<T: store>(self: &Receipt<T>): ID { object::id(self) }

/// Line items copied from the originating invoice or voucher.
public fun items<T>(self: &Receipt<T>): &vector<Item> { &self.items }

/// Total settled amount (stablecoin for payment, LOYALTY for redemption).
public fun amount<T>(self: &Receipt<T>): u64 { self.amount }

/// Settlement timestamp (ms since epoch).
public fun timestamp_ms<T>(self: &Receipt<T>): u64 { self.timestamp_ms }

/// ID of the `Invoice` this receipt settled.
public fun invoice_id(self: &Receipt<Payment>): ID { self.data.invoice_id }

/// Payout address recorded at settlement.
public fun payout_address(self: &Receipt<Payment>): address { self.data.payout_address }

/// LOYALTY units minted to the customer on settlement.
public fun loyalty(self: &Receipt<Payment>): u64 { self.data.loyalty }

/// Merchant-supplied order reference carried over from the invoice.
public fun order_ref(self: &Receipt<Payment>): &vector<u8> { &self.data.order_ref }

/// `TypeName` of the stablecoin the customer paid in.
public fun payment_type(self: &Receipt<Payment>): TypeName { self.data.payment_type }

/// ID of the `Voucher` this receipt settled.
public fun voucher_id(self: &Receipt<Redemption>): ID { self.data.voucher_id }

// === Package Functions ===

/// Build an order line by snapshotting the variant's current stablecoin price
/// from the merchant's catalog. `quantity` must be > 0. Aborts if the variant
/// is not registered or its parent listing is inactive (via
/// `merchant::active_listing_variant`).
public(package) fun new_item(merchant: &Merchant, variant_id: ID, quantity: u64): Item {
    assert!(quantity > 0, EZeroQuantity);

    let price = merchant.active_listing_variant(&variant_id).price();

    Item { variant_id, quantity, price }
}

/// Build a voucher line by snapshotting the variant's current `loyalty_price`
/// from the merchant's catalog. `quantity` must be > 0. Aborts with
/// `ENoLoyaltyPrice` if the variant does not declare a loyalty-side price
/// (i.e. `Variant.loyalty_price` is `None`), and propagates the abort from
/// `merchant::active_listing_variant` if the variant is not registered or its
/// parent listing is inactive.
public(package) fun new_loyalty_item(merchant: &Merchant, variant_id: ID, quantity: u64): Item {
    assert!(quantity > 0, EZeroQuantity);

    let price = merchant
        .active_listing_variant(&variant_id)
        .loyalty_price()
        .destroy_or!(abort ENoLoyaltyPrice);

    Item { variant_id, quantity, price }
}

/// Sum `item.quantity * item.price` across all items using a u128
/// accumulator; aborts with `EAmountOverflow` if the final total doesn't fit
/// in u64.
public(package) fun compute_total(items: &vector<Item>): u64 {
    let mut total: u64 = 0;
    items.do_ref!(|item| {
        let position_total = item
            .quantity
            .checked_mul(item.price)
            .destroy_or!(abort EAmountOverflow);
        total = total.checked_add(position_total).destroy_or!(abort EAmountOverflow);
    });

    total
}

/// Mint a `Receipt<Payment>` and transfer it to `customer`.
/// Soulbound (receipt cannot be re-transferred or stored anywhere else).
public(package) fun transfer_payment_receipt(
    invoice_id: ID,
    payout_address: address,
    payment_type: TypeName,
    items: vector<Item>,
    amount: u64,
    loyalty: u64,
    order_ref: vector<u8>,
    timestamp_ms: u64,
    customer: address,
    ctx: &mut TxContext,
) {
    let receipt = Receipt<Payment> {
        id: object::new(ctx),
        items,
        amount,
        timestamp_ms,
        data: Payment { invoice_id, payout_address, payment_type, loyalty, order_ref },
    };
    transfer::transfer(receipt, customer);
}

/// Mint a `Receipt<Redemption>` and transfer it to `customer`.
/// Soulbound (receipt cannot be re-transferred or stored anywhere else).
public(package) fun transfer_redemption_receipt(
    voucher_id: ID,
    items: vector<Item>,
    amount: u64,
    timestamp_ms: u64,
    customer: address,
    ctx: &mut TxContext,
) {
    let receipt = Receipt<Redemption> {
        id: object::new(ctx),
        items,
        amount,
        timestamp_ms,
        data: Redemption { voucher_id },
    };
    transfer::transfer(receipt, customer);
}
