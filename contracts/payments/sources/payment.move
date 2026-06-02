/// Invoice — merchant-issued payment intent + customer-side settlement.
///
/// Merchant POS issues an `Invoice` via
/// `payment::new(merchant, &auth, listing_variant_ids, quantities, ...)` (gated by
/// `Auth<CashierRole>`).
/// `Item` line entries are derived inside `new` by snapshotting each variant's
/// current price; the resulting `amount` total is the sum of `quantity * price`,
/// and the `loyalty` to be granted on settlement is snapshotted from the
/// merchant's `Config` at issuance — subsequent `set_config` calls do not retroactively
/// affect open invoices.
/// Merchant calls `payment::share(invoice)` and surfaces
/// the object ID through a QR. Customer scans and calls `payment::pay<S>(...)`,
/// which resolves the customer's already-approved PAS `send_funds` request
/// (transfers stablecoin into the merchant's PAS Account), mints loyalty rewards
/// into the customer's PAS Account, destroys the Invoice, and emits `InvoicePaid`.
///
/// Cleanup: `payment::cancel(invoice, &clock)` (permissionless after expiry).
module openzeppelin_payments::payment;

use openzeppelin_access::access_control::Auth;
use openzeppelin_payments::events;
use openzeppelin_payments::loyalty;
use openzeppelin_payments::merchant::{Self, Merchant, CashierRole};
use openzeppelin_payments::receipt::{Self, Item};
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
const ENotExpired: vector<u8> = b"Invoice has not yet expired";
#[error(code = 2)]
const EInvoiceExpired: vector<u8> = b"Invoice has expired";
#[error(code = 3)]
const EAmountMismatch: vector<u8> = b"Send amount does not match Invoice amount";
#[error(code = 4)]
const EWrongRecipient: vector<u8> = b"Send recipient does not match Invoice payout_address";
#[error(code = 5)]
const EWrongLoyaltyRecipient: vector<u8> = b"Loyalty account owner does not match payer";
#[error(code = 6)]
const ENoItems: vector<u8> = b"Invoice must include at least one item";
#[error(code = 7)]
const ELengthMismatch: vector<u8> = b"listing_variant_ids and quantities must have the same length";

// === Structs ===

/// Merchant-issued invoice. Customer scans `id` from a QR and settles via `pay`.
///
/// NOTE: No `merchant_id` field: the package's single-Merchant invariant means there's
/// only one Merchant any Invoice could be against.
public struct Invoice has key {
    /// Object ID. Surfaced via QR for the customer to scan and look up the
    /// shared object.
    id: UID,
    /// Snapshot of `merchant.payout_address` at issuance. Later
    /// `set_payout_address` calls do not retarget open invoices.
    payout_address: address,
    /// Line items with snapshot prices. Each entry's `price` is in stablecoin
    /// units (see `receipt::new_item`).
    items: vector<Item>,
    /// Total stablecoin amount due, computed from `items` at issuance.
    amount: u64,
    /// Loyalty units the customer earns on settlement. Snapshotted from the
    /// merchant's `Config` at issuance so subsequent `set_config` calls don't
    /// change what's owed on this invoice.
    loyalty: u64,
    /// Merchant-supplied opaque tag (e.g. POS order number). Carried through
    /// to `Receipt<Payment>.order_ref` and the `InvoicePaid` event.
    order_ref: vector<u8>,
    /// Expiry timestamp (ms). Past this point `pay` aborts and `cancel`
    /// becomes permissionless.
    expires_at_ms: u64,
}

// === Public Functions ===

/// Merchant issues an Invoice from parallel `listing_variant_ids` + `quantities`
/// vectors; each pair is resolved into an `Item` by snapshotting the variant's
/// current price from the merchant's catalog. The total `amount` is computed
/// from those items, and `expires_at_ms` uses the merchant's `Config.invoice_ttl_ms`.
/// Aborts if the vectors are empty (`ENoItems`), if their lengths differ
/// (`ELengthMismatch`), if the computed total is 0 (`EZeroAmount`), or if any
/// variant ID is not registered in the merchant's catalog.
public fun new(
    merchant: &Merchant,
    _auth: &Auth<CashierRole>,
    listing_variant_ids: vector<ID>,
    quantities: vector<u64>,
    order_ref: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): Invoice {
    assert!(!listing_variant_ids.is_empty(), ENoItems);
    assert!(listing_variant_ids.length() == quantities.length(), ELengthMismatch);

    let items = listing_variant_ids.zip_map!(quantities, |vid, qty| {
        receipt::new_item(merchant, vid, qty)
    });

    let amount = receipt::compute_total(&items);
    assert!(amount > 0, EZeroAmount);

    let config = merchant.config();
    let loyalty = config.compute_loyalty(amount);

    let invoice = Invoice {
        id: object::new(ctx),
        payout_address: merchant::payout_address(merchant),
        items,
        amount,
        loyalty,
        order_ref,
        expires_at_ms: clock.timestamp_ms() + config.invoice_ttl_ms(),
    };

    events::emit_invoice_created(object::id(&invoice));

    invoice
}

/// Share the `Invoice`. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` is restricted to this module.
public fun share(invoice: Invoice) {
    transfer::share_object(invoice);
}

/// Customer settles the invoice. Resolves the customer's already-approved stablecoin
/// `send_funds` request (transfers `Balance<S>` from customer's PAS Account to the
/// merchant's), mints loyalty rewards into the customer's PAS `Account<LOYALTY>`,
/// destroys the Invoice, mints a soulbound `PaymentReceipt` for the customer, and
/// emits `InvoicePaid`.
public fun pay<S>(
    invoice: Invoice,
    merchant: &mut Merchant,
    send_request: Request<SendFunds<Balance<S>>>,
    policy_s: &Policy<Balance<S>>,
    customer_loyalty_account: &Account,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now = clock.timestamp_ms();
    let invoice_id = object::id(&invoice);

    // Invoice validity
    assert!(now < invoice.expires_at_ms, EInvoiceExpired);

    // Send-request integrity
    let data = send_request.data();
    assert!(data.recipient() == invoice.payout_address, EWrongRecipient);
    assert!(data.funds().value() == invoice.amount, EAmountMismatch);

    // Loyalty mints to the payer's own account
    let sender = data.sender();
    assert!(customer_loyalty_account.owner() == sender, EWrongLoyaltyRecipient);

    // Consume the invoice — both amounts are already snapshotted on it
    let Invoice {
        id,
        payout_address,
        items,
        amount,
        loyalty,
        order_ref,
        expires_at_ms: _,
    } = invoice;
    id.delete();

    // Resolve send_funds — transfers stablecoin into the merchant's PAS Account
    send_funds::resolve_balance(send_request, policy_s);

    // Mint the loyalty snapshotted at issuance
    if (loyalty > 0) {
        loyalty::mint_into(
            merchant.loyalty_mut().treasury_cap_mut(),
            customer_loyalty_account,
            loyalty,
        );
    };

    // Soulbound receipt to the customer
    receipt::transfer_payment_receipt(
        invoice_id,
        payout_address,
        items,
        amount,
        loyalty,
        order_ref,
        now,
        sender,
        ctx,
    );

    events::emit_invoice_paid(
        invoice_id,
        order_ref,
        sender,
        amount,
        loyalty,
        now,
    );
}

/// Permissionless cleanup of an expired Invoice. No balance is held by the Invoice
/// (customer balance stays in their Account until settlement), so this is just
/// object destruction.
public fun cancel(invoice: Invoice, clock: &Clock) {
    assert!(clock.timestamp_ms() >= invoice.expires_at_ms, ENotExpired);

    let Invoice { id, order_ref, .. } = invoice;

    events::emit_invoice_canceled(id.to_inner(), order_ref);

    id.delete();
}

// === View Functions ===

/// Object ID of the shared `Invoice`.
public fun id(self: &Invoice): ID { object::id(self) }

/// Address that will receive the customer's stablecoin on `pay`.
public fun payout_address(self: &Invoice): address { self.payout_address }

/// Line items, each carrying `variant_id`, `quantity`, and snapshot `price`.
public fun items(self: &Invoice): &vector<Item> { &self.items }

/// Total stablecoin due, computed from `items` at issuance.
public fun amount(self: &Invoice): u64 { self.amount }

/// Loyalty units that will be minted to the customer on settlement (snapshotted
/// from the merchant's `Config` at issuance).
public fun loyalty(self: &Invoice): u64 { self.loyalty }

/// Merchant-supplied order reference (opaque bytes, surfaced in `InvoicePaid`).
public fun order_ref(self: &Invoice): &vector<u8> { &self.order_ref }

/// Expiry timestamp (ms). After this point `pay` aborts with `EInvoiceExpired`
/// and `cancel` becomes permissionless.
public fun expires_at_ms(self: &Invoice): u64 { self.expires_at_ms }
