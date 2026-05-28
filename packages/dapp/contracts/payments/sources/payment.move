/// Invoice — merchant-issued payment intent + customer-side settlement.
///
/// Merchant POS issues an `Invoice` via `invoice::new(merchant, &cap, items, ...)`
/// (cap-gated). Each invoice carries a vector of `Item` line entries
/// (variant_id, quantity, unit_price) and an `amount` total computed
/// from them at issuance. Merchant calls `invoice::share(invoice)` and surfaces
/// the object ID through a QR. Customer scans and calls `invoice::pay<S>(...)`,
/// which resolves the customer's already-approved PAS `send_funds` request
/// (transfers stablecoin into the merchant's PAS Account), mints loyalty rewards
/// into the customer's PAS Account, destroys the Invoice, and emits `InvoicePaid`.
///
/// Cleanup: `invoice::cancel(invoice, &clock)` (permissionless after expiry).
module openzeppelin_payments::invoice;

use openzeppelin_payments::events;
use openzeppelin_payments::loyalty;
use openzeppelin_payments::merchant::{Self, Merchant, MerchantCap, Item};
use pas::account::Account;
use pas::policy::Policy;
use pas::request::Request;
use pas::send_funds::{Self, SendFunds};
use sui::balance::Balance;
use sui::clock::Clock;

// === Errors ===

#[error(code = 0)]
const EZeroAmount: vector<u8> = b"Invoice amount must be greater than zero";
#[error(code = 1)]
const EZeroTtl: vector<u8> = b"Invoice ttl_ms must be greater than zero";
#[error(code = 2)]
const ENotExpired: vector<u8> = b"Invoice has not yet expired";
#[error(code = 3)]
const EInvoiceExpired: vector<u8> = b"Invoice has expired";
#[error(code = 4)]
const EAmountMismatch: vector<u8> = b"Send amount does not match Invoice amount";
#[error(code = 5)]
const EWrongRecipient: vector<u8> = b"Send recipient does not match Invoice payout_address";
#[error(code = 6)]
const EWrongLoyaltyRecipient: vector<u8> = b"Loyalty account owner does not match payer";
#[error(code = 7)]
const ENoItems: vector<u8> = b"Invoice must include at least one item";
#[error(code = 8)]
const EAmountOverflow: vector<u8> = b"Invoice amount exceeds u64 range";

// === Structs ===

/// Merchant-issued invoice. Customer scans `id` from a QR and settles via `pay`.
///
/// NOTE: No `merchant_id` field: the package's single-Merchant invariant means there's
/// only one Merchant any Invoice could be against.
public struct Invoice has key {
    id: UID,
    payout_address: address,
    items: vector<Item>,
    amount: u64,
    order_ref: vector<u8>,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Merchant issues an Invoice from a list of `Item`s. The total `amount` is computed
/// from the items at issuance; at least one item is required and total must be > 0.
public fun new(
    merchant: &Merchant,
    _: &MerchantCap,
    items: vector<Item>,
    order_ref: vector<u8>,
    ttl_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Invoice {
    assert!(!items.is_empty(), ENoItems);
    assert!(ttl_ms > 0, EZeroTtl);

    let amount = compute_total(&items);
    assert!(amount > 0, EZeroAmount);

    Invoice {
        id: object::new(ctx),
        payout_address: merchant::payout_address(merchant),
        items,
        amount,
        order_ref,
        expires_at_ms: clock.timestamp_ms() + ttl_ms,
    }
}

/// Share the `Invoice`. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` is restricted to this module.
public fun share(invoice: Invoice) {
    transfer::share_object(invoice);
}

// TODO#q: return receipt

/// Customer settles the invoice. Resolves the customer's already-approved stablecoin
/// `send_funds` request (transfers `Balance<S>` from customer's PAS Account to the
/// merchant's), mints loyalty rewards into the customer's PAS `Account<LOYALTY>`,
/// destroys the Invoice, and emits `InvoicePaid`.
public fun pay<S>(
    invoice: Invoice,
    merchant: &mut Merchant,
    send_request: Request<SendFunds<Balance<S>>>,
    policy_s: &Policy<Balance<S>>,
    customer_loyalty_account: &Account,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let now = clock.timestamp_ms();
    let invoice_id = object::id(&invoice);
    let merchant_id = object::id(merchant);

    // Invoice validity
    assert!(now < invoice.expires_at_ms, EInvoiceExpired);

    // Send-request integrity
    let data = send_request.data();
    let sender = data.sender();
    assert!(data.recipient() == invoice.payout_address, EWrongRecipient);
    assert!(data.funds().value() == invoice.amount, EAmountMismatch);

    // Loyalty mints to the payer's own account
    assert!(customer_loyalty_account.owner() == sender, EWrongLoyaltyRecipient);

    // Snapshot mint params (immutable read) and consume the invoice
    let (num, den, max) = merchant::mint_params(merchant);
    let Invoice { id, amount: payment_amount, order_ref, .. } = invoice;
    id.delete();

    // Resolve send_funds — transfers stablecoin into the merchant's PAS Account
    send_funds::resolve_balance(send_request, policy_s);

    // Compute and mint loyalty
    let raw: u128 = (payment_amount as u128) * (num as u128) / (den as u128);
    let mint_amount: u64 = if (raw > (max as u128)) { max } else { (raw as u64) };
    if (mint_amount > 0) {
        loyalty::mint_into(
            merchant::loyalty_treasury_cap_mut(merchant),
            customer_loyalty_account,
            mint_amount,
        );
    };

    events::emit_invoice_paid(
        invoice_id,
        merchant_id,
        order_ref,
        sender,
        payment_amount,
        mint_amount,
        now,
    );
}

/// Permissionless cleanup of an expired Invoice. No balance is held by the Invoice
/// (customer balance stays in their Account until settlement), so this is just
/// object destruction.
public fun cancel(invoice: Invoice, clock: &Clock) {
    assert!(clock.timestamp_ms() >= invoice.expires_at_ms, ENotExpired);
    let Invoice { id, .. } = invoice;
    id.delete();
}

// === View Functions ===

public fun payout_address(self: &Invoice): address { self.payout_address }

public fun items(self: &Invoice): &vector<Item> { &self.items }

public fun amount(self: &Invoice): u64 { self.amount }

public fun order_ref(self: &Invoice): &vector<u8> { &self.order_ref }

public fun expires_at_ms(self: &Invoice): u64 { self.expires_at_ms }

// === Private Functions ===

/// Sum `item.quantity * item.unit_price` across all items using a u128 accumulator,
/// asserting the final total fits in u64 (otherwise aborts with `EAmountOverflow`).
fun compute_total(items: &vector<Item>): u64 {
    let mut total: u128 = 0;
    items.do_ref!(|item| {
        total = total + (item.quantity() as u128) * (item.unit_price() as u128);
    });

    total.try_as_u64().destroy_or!(abort EAmountOverflow)
}
