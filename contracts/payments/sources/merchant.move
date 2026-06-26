/// Merchant identity, central state, and the full settlement surface. The
/// `Merchant` shared object stores the catalog plus open invoices, open vouchers,
/// and settlement receipts in `Table`s, and owns the issuance + settlement flows
/// for both asset sides (invoice -> stablecoin payment, redemption -> loyalty burn).
///
/// `payment` and `redemption` are thin data-type modules (`Invoice` / `Voucher`
/// plus dumb constructors); this module depends on them and on `receipt`. Because
/// `Merchant` stores `Table<ID, Invoice>` / `Table<ID, Voucher>` and the receipt
/// tables (`Table<ID, Receipt<Payment>>` / `Table<ID, Receipt<Redemption>>`), those
/// modules must NOT depend back on `merchant` (it would form a cycle), so all
/// merchant-aware logic lives here.
///
/// Access control: `AccessControl<MERCHANT>` (from `openzeppelin_access`) is
/// created in `init` as a shared object. The root role is the `MERCHANT` OTW
/// itself; the deployer becomes its sole holder. Three operational roles split
/// the admin surface:
///   - `MerchantRole`         -> merchant-level identity + treasury settings
///                              (`set_payout_address`, `update_config`, `update_display`)
///   - `CatalogManagerRole`   -> catalog CRUD (`add_listing`, `remove_listing`,
///                              `set_listing_status`, `add_listing_variant`,
///                              `remove_listing_variant`)
///   - `CashierRole`          -> settlement (`create_invoice`, `redeem`)
/// Each role's default admin is the root role, so the root holder can
/// grant/revoke via `access_control::grant_role` / `revoke_role`. None of the
/// operational roles are auto-granted by `init` - the deployer (root holder)
/// is expected to grant them explicitly in the bootstrap PTB, which also lets
/// them assign roles to different addresses (cold-storage root, hot-wallet
/// operator) from the outset.
///
/// Two-step deployment:
///   1. `sui publish` runs both `loyalty::init` (LOYALTY currency) and
///      `merchant::init` (AccessControl<MERCHANT>). The deployer holds:
///      - `TreasuryCap<LOYALTY>` (owned, to be consumed by `loyalty::create`),
///      - root role on the shared `AccessControl<MERCHANT>`.
///   2. Deployer's PTB:
///        loyalty   = loyalty::create(&mut namespace, treasury_cap)
///        config    = config::new(num, den, max, invoice_ttl_ms, voucher_ttl_ms)
///        merchant  = merchant::create(loyalty, config, name, logo_url, payout, ctx)
///        merchant::share(merchant)
///        ac.grant_role<MERCHANT, MerchantRole>(merchant_admin_addr, ctx)
///        ac.grant_role<MERCHANT, CatalogManagerRole>(catalog_op_addr, ctx)
///        ac.grant_role<MERCHANT, CashierRole>(pos_addr, ctx)
module openzeppelin_payments::merchant;

use openzeppelin_access::access_control::{Self, Auth};
use openzeppelin_payments::config::Config;
use openzeppelin_payments::events;
use openzeppelin_payments::listing::{Listing, Variant};
use openzeppelin_payments::loyalty::{Self, Loyalty, LOYALTY};
use openzeppelin_payments::payment::{Self, Invoice};
use openzeppelin_payments::receipt::{Self, Item, Receipt, Payment, Redemption};
use openzeppelin_payments::redemption::{Self, Voucher};
use pas::account::Account;
use pas::policy::Policy;
use pas::request::Request;
use pas::send_funds::{Self, SendFunds};
use pas::unlock_funds::{Self, UnlockFunds};
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::hash;
use sui::table::{Self, Table};

// === Errors ===

#[error(code = 0)]
const EEmptyName: vector<u8> = "Name cannot be empty";
#[error(code = 1)]
const EListingNotFound: vector<u8> = "Listing not found";
#[error(code = 2)]
const EVariantNotFound: vector<u8> = "Listing variant not found";
#[error(code = 3)]
const EConfigUnchanged: vector<u8> = "Config matches the current value";
#[error(code = 4)]
const EDisplayUnchanged: vector<u8> = "Display name and logo both match the current values";
#[error(code = 5)]
const EListingInactive: vector<u8> = "Listing is inactive and cannot be sold or redeemed";
#[error(code = 6)]
const EZeroAmount: vector<u8> = "Amount must be greater than zero";
#[error(code = 7)]
const ENoItems: vector<u8> = "Must include at least one item";
#[error(code = 8)]
const ELengthMismatch: vector<u8> = "listing_variant_ids and quantities must have the same length";
#[error(code = 9)]
const EZeroQuantity: vector<u8> = "Item quantity must be greater than zero";
#[error(code = 10)]
const ENoLoyaltyPrice: vector<u8> = "Variant is not redeemable: loyalty_price is not set";
#[error(code = 11)]
const EInvoiceNotFound: vector<u8> = "Invoice not found";
#[error(code = 12)]
const EInvoiceExpired: vector<u8> = "Invoice has expired";
#[error(code = 13)]
const EWrongPaymentType: vector<u8> =
    "Send currency does not match merchant's accepted payment type";
#[error(code = 14)]
const EWrongRecipient: vector<u8> = "Send recipient does not match Invoice payout_address";
#[error(code = 15)]
const EAmountMismatch: vector<u8> = "Send amount does not match Invoice amount";
#[error(code = 16)]
const EWrongLoyaltyRecipient: vector<u8> = "Loyalty account owner does not match payer";
#[error(code = 17)]
const ENotExpired: vector<u8> = "Not yet expired";
#[error(code = 18)]
const EVoucherNotFound: vector<u8> = "Voucher not found";
#[error(code = 19)]
const EVoucherExpired: vector<u8> = "Voucher has expired";
#[error(code = 20)]
const EWrongCustomer: vector<u8> = "Account owner does not match Voucher customer";
#[error(code = 21)]
const EInvalidAmount: vector<u8> = "Voucher amount must equal the total redeemed amount";
#[error(code = 22)]
const EReceiptNotFound: vector<u8> = "Receipt not found";
#[error(code = 23)]
const EBadHashLength: vector<u8> = "Voucher redeem_hash must be 32 bytes";
#[error(code = 24)]
const EWrongPreimage: vector<u8> =
    "Provided preimage does not match the voucher's redeem_hash commitment";
#[error(code = 25)]
const EOrderRefTooLong: vector<u8> = "order_ref exceeds MAX_ORDER_REF_LEN (256 bytes)";
#[error(code = 26)]
const EItemsTooMany: vector<u8> = "listing_variant_ids exceeds MAX_INVOICE_ITEMS (256 items)";

// === Constants ===

/// Timelock (in ms) applied to root role transfer / renounce on the shared
/// `AccessControl<MERCHANT>`. 24 hours.
const ROOT_TRANSFER_DELAY_MS: u64 = 86_400_000;

/// Maximum length (bytes) of the cashier-supplied `order_ref` on an invoice.
/// `order_ref` is snapshotted into both the stored `Receipt<Payment>` and the
/// `InvoicePaid` / `InvoiceCanceled` events.
/// Capping it here keeps a single invoice's contribution to per-tx effects bounded,
/// so an oversized ref can't brick the settle/cancel paths and leave an invoice stuck.
/// 256 bytes covers all common POS reference formats (UUIDs, ULIDs, Shopify order names,
/// composite prefixes) with generous headroom.
const MAX_ORDER_REF_LEN: u64 = 256;

/// Maximum number of line items on a single invoice or voucher. Bounds the
/// `items` vector that's snapshotted into the stored `Receipt` and propagated
/// to events at settlement, so an oversized invoice/voucher can't push effects
/// past per-tx limits and brick the settle/cancel paths. 256 items is
/// generous for any realistic POS flow (typical receipts ≤ 30, grocery hauls
/// rarely > 100).
const MAX_INVOICE_ITEMS: u64 = 256;

// === Structs ===

/// One-time witness - struct name == module name uppercased. Consumed once
/// in `init` to mint the package's `AccessControl<MERCHANT>` registry.
public struct MERCHANT has drop {}

/// Holder gates merchant-level identity/treasury operations:
/// `set_payout_address`, `update_config`, `update_display`.
public struct MerchantRole {}

/// Holder gates catalog CRUD: `add_listing`, `remove_listing`,
/// `set_listing_status`, `add_listing_variant`, `remove_listing_variant`.
public struct CatalogManagerRole {}

/// Holder gates settlement entry points: `create_invoice` / `redeem`.
public struct CashierRole {}

/// Central shared object holding the merchant's entire on-chain state. The
/// accepted stablecoin currency is identified by `config.accepted_payment_type`
/// (snapshotted from `type_name::with_defining_ids<C>()` at `config::new<C>` time);
/// `pay<C>` checks `type_name::with_defining_ids<C>() == config.accepted_payment_type`
/// at runtime to enforce the binding.
public struct Merchant has key {
    id: UID,
    /// Display name (e.g. "Joe's Coffee"). Mutable via `update_display`.
    name: String,
    /// Optional logo URL. Mutable via `update_display`.
    logo_url: Option<String>,
    /// Loyalty asset bundle (treasury cap, policy cap, policy id). Stored whole;
    /// read via `loyalty()`. The treasury cap is reached internally by `pay`
    /// (mint) and `redeem` (burn).
    loyalty: Loyalty,
    /// Full merchant configuration — payout address, accepted payment type,
    /// payment decimals, loyalty mint rate, and TTLs. Replaceable atomically via
    /// `update_config`. Changes do not affect already-issued invoices, which
    /// snapshot `amount`/`loyalty`/`payout_address`/`payment_type` at creation.
    config: Config,
    /// Listing CRUD lives below; this is the storage. Keys are freshly-generated
    /// `ID`s (via `tx_context::fresh_object_address`).
    listings: Table<ID, Listing>,
    /// Reverse index: `variant_id -> listing_id`. Lets checkout look up a variant
    /// from a single ID without the customer having to carry both IDs. Maintained
    /// in lockstep with `Listing.variants` by `add_listing`/`remove_listing` and
    /// `add_listing_variant`/`remove_listing_variant`.
    variant_index: Table<ID, ID>,
    /// Open invoices, keyed by their freshly-minted issuance ID (the QR value).
    /// Inserted by `create_invoice`, removed by `pay` / `cancel_invoice`.
    invoices: Table<ID, Invoice>,
    /// Open vouchers, keyed by their freshly-minted issuance ID (the QR value).
    /// Inserted by `create_voucher`, removed by `redeem` / `cancel_voucher`.
    vouchers: Table<ID, Voucher>,
    /// Payment receipts, keyed by the settled invoice ID. The recipient is
    /// recorded in `Receipt.customer`. Grows monotonically - the merchant bears
    /// the storage. Customer-scoped history is served off-chain from the
    /// `InvoicePaid` event stream.
    invoice_receipts: Table<ID, Receipt<Payment>>,
    /// Redemption receipts, keyed by the redeemed voucher ID. Same lifecycle and
    /// off-chain history story as `invoice_receipts`, via `VoucherRedeemed`.
    voucher_receipts: Table<ID, Receipt<Redemption>>,
}

// === Init ===

/// Module init - runs once on package publish. Creates the
/// `AccessControl<MERCHANT>` shared registry and shares it. The root role is
/// granted to the deployer by `access_control::new`. Operational roles
/// (`MerchantRole`, `CatalogManagerRole`, `CashierRole`) are NOT pre-granted
/// here - the deployer grants them explicitly in the bootstrap PTB (typically
/// to different addresses than the root key).
///
/// #### Parameters
/// - `otw`: The `MERCHANT` one-time witness, consumed to mint the registry.
/// - `ctx`: Transaction context.
fun init(otw: MERCHANT, ctx: &mut TxContext) {
    let ac = access_control::new(otw, ROOT_TRANSFER_DELAY_MS, ctx);
    transfer::public_share_object(ac);
}

// === Public Functions ===

/// Consume the `Loyalty` bundle from `loyalty::create` and return the `Merchant`.
///
/// Bootstrap-only: the `Loyalty` linear resource is the gating mechanism;
/// subsequent admin operations are gated by `MerchantRole` /
/// `CatalogManagerRole` / `CashierRole` via `AccessControl<MERCHANT>`. Caller is
/// expected to follow up with `merchant::share(merchant)` in the same PTB.
///
/// #### Parameters
/// - `loyalty`: The `Loyalty` bundle from `loyalty::create`.
/// - `config`: The merchant's `Config` — payout address, accepted payment type,
///   decimals, loyalty rate, TTLs. Built via `config::new<C>(&currency, ...)`,
///   which pins the accepted currency.
/// - `name`: Display name. Must be non-empty.
/// - `logo_url`: Optional logo URL.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - The constructed `Merchant` (caller must `share` it).
///
/// #### Aborts
/// - `EEmptyName` if `name` is empty.
public fun create(
    loyalty: Loyalty,
    config: Config,
    name: String,
    logo_url: Option<String>,
    ctx: &mut TxContext,
): Merchant {
    assert!(!name.is_empty(), EEmptyName);

    Merchant {
        id: object::new(ctx),
        name,
        logo_url,
        loyalty,
        config,
        listings: table::new(ctx),
        variant_index: table::new(ctx),
        invoices: table::new(ctx),
        vouchers: table::new(ctx),
        invoice_receipts: table::new(ctx),
        voucher_receipts: table::new(ctx),
    }
}

/// Share the `Merchant`. Required because `Merchant` is `key`-only (no `store`),
/// so `transfer::share_object` can only be called from this module — an external
/// caller can't share it directly. Call after `create` and any same-PTB setup.
public fun share(self: Merchant) {
    transfer::share_object(self);
}

/// Customer settles an open invoice with a permissioned (PAS) stablecoin.
///
/// Resolves the customer's approved `send_funds` request (moving the
/// `Balance<C>` into the merchant's payout PAS Account), mints the snapshotted
/// loyalty into the customer's PAS account, removes the invoice, stores a
/// `Receipt<Payment>` keyed by `invoice_id`, and emits `InvoicePaid`.
/// Permissionless - anyone holding a matching send request can pay.
///
/// For settling with a plain, unrestricted coin instead, see `pay_with_coin`.
///
/// #### Generics
/// - `C`: The settlement coin type; must match the merchant's accepted payment
///   type (checked at runtime via `config.accepted_payment_type`).
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `invoice_id`: Issuance id of the open invoice being settled.
/// - `send_request`: Customer-approved `send_funds` request whose recipient is
///   the invoice's `payout_address` and whose amount is exactly `invoice.amount`.
/// - `policy_s`: Shared `Policy<Balance<C>>` for the stablecoin. Consulted by
///   `send_funds::resolve_balance` to validate the request's approvals.
/// - `customer_loyalty_account`: PAS Account that receives the minted LOYALTY.
///   Its owner must equal the send request's sender.
/// - `clock`: System clock (for expiry).
///
/// #### Aborts
/// - `EInvoiceNotFound` if no open invoice with `invoice_id` is stored.
/// - `EInvoiceExpired` if the invoice has expired.
/// - `EWrongPaymentType` if `C` does not match the invoice's `payment_type`.
/// - `EWrongRecipient` if the send request's recipient is not the payout address.
/// - `EAmountMismatch` if the sent amount is not the invoice amount.
/// - `EWrongLoyaltyRecipient` if the loyalty account owner is not the sender.
/// - Propagates from `send_funds::resolve_balance` if the request's approvals do
///   not satisfy the stablecoin `Policy<Balance<C>>`.
/// - Propagates from `loyalty::mint_to` if minting `loyalty` would overflow the
///   `LOYALTY` total supply.
public fun pay<C>(
    self: &mut Merchant,
    invoice_id: ID,
    send_request: Request<SendFunds<Balance<C>>>,
    policy_s: &Policy<Balance<C>>,
    customer_loyalty_account: &Account,
    clock: &Clock,
) {
    assert!(self.invoices.contains(invoice_id), EInvoiceNotFound);

    let (payout_address, payment_type, items, amount, loyalty, order_ref, expires_at_ms) = self
        .invoices
        .remove(invoice_id)
        .unpack();

    let now = clock.timestamp_ms();
    assert!(now < expires_at_ms, EInvoiceExpired);
    // Otherwise a customer could mint their own coin and settle in junk tokens.
    assert!(type_name::with_defining_ids<C>() == payment_type, EWrongPaymentType);

    // Validate PaS send request.
    let data = send_request.data();
    assert!(data.recipient() == payout_address, EWrongRecipient);
    assert!(data.funds().value() == amount, EAmountMismatch);
    let sender = data.sender();
    assert!(customer_loyalty_account.owner() == sender, EWrongLoyaltyRecipient);

    // Resolve send request and send funds to payout_address.
    send_funds::resolve_balance(send_request, policy_s);

    // Mint the loyalty tokens snapshotted at issuance.
    if (loyalty > 0) {
        self.loyalty.mint_to(customer_loyalty_account, loyalty);
    };

    // Store the receipt under the invoice's issuance ID: a fresh, single-use ID
    // removed from `invoices` above, so `invoice_receipts.add` can never collide.
    let receipt = receipt::new_payment(
        sender,
        items,
        amount,
        now,
        invoice_id,
        payout_address,
        payment_type,
        loyalty,
        order_ref,
    );
    self.invoice_receipts.add(invoice_id, receipt);

    events::emit_invoice_paid(
        invoice_id,
        order_ref,
        sender,
        payout_address,
        payment_type,
        amount,
        loyalty,
        now,
        false,
    );
}

/// Customer settles an open invoice with a plain, unrestricted `Coin<C>`.
///
/// The open-loop counterpart to `pay`: instead of a PAS `send_funds` request,
/// the caller hands over a regular coin, which the merchant transfers in full to
/// the invoice's `payout_address` (as an owned `Coin<C>`, NOT into a PAS Account).
/// Loyalty is still minted into `customer_loyalty_account`, and that account's
/// owner is recorded as the receipt's `customer`. Permissionless.
///
/// NOTE: unlike `pay`, there is no `send_funds` sender to bind the payer's
/// identity - the caller designates the loyalty recipient, and the receipt's
/// `customer` is that account's owner. This is safe (loyalty is a reward, so
/// directing it is gifting, not taking), but the `customer` is "whoever was
/// named," not a cryptographically-proven payer.
///
/// #### Generics
/// - `C`: The settlement coin type; must match the merchant's accepted payment
///   type (checked at runtime via `config.accepted_payment_type`).
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `invoice_id`: Issuance id of the open invoice being settled.
/// - `coin`: Payment coin. Its value must equal the invoice's `amount`; the full
///   coin is transferred to the snapshotted `payout_address`.
/// - `customer_loyalty_account`: PAS Account that receives the minted LOYALTY.
///   Its owner is recorded as the receipt's `customer`.
/// - `clock`: System clock (for expiry).
///
/// #### Aborts
/// - `EInvoiceNotFound` if no open invoice with `invoice_id` is stored.
/// - `EInvoiceExpired` if the invoice has expired.
/// - `EWrongPaymentType` if `C` does not match the invoice's `payment_type`.
/// - `EAmountMismatch` if `coin.value()` is not the invoice amount.
/// - Propagates from `loyalty::mint_to` if minting `loyalty` would overflow the
///   `LOYALTY` total supply.
public fun pay_with_coin<C>(
    self: &mut Merchant,
    invoice_id: ID,
    coin: Coin<C>,
    customer_loyalty_account: &Account,
    clock: &Clock,
) {
    assert!(self.invoices.contains(invoice_id), EInvoiceNotFound);

    let (payout_address, payment_type, items, amount, loyalty, order_ref, expires_at_ms) = self
        .invoices
        .remove(invoice_id)
        .unpack();

    let now = clock.timestamp_ms();
    assert!(now < expires_at_ms, EInvoiceExpired);
    // Otherwise a customer could mint their own coin and settle in junk tokens.
    assert!(type_name::with_defining_ids<C>() == payment_type, EWrongPaymentType);

    // Exact payment; the merchant routes the coin to the payout address.
    assert!(coin.value() == amount, EAmountMismatch);
    transfer::public_transfer(coin, payout_address);

    // No send-request sender here: the loyalty account's owner is the customer.
    let customer = customer_loyalty_account.owner();

    // Mint the loyalty tokens snapshotted at issuance.
    if (loyalty > 0) {
        self.loyalty.mint_to(customer_loyalty_account, loyalty);
    };

    // Store the receipt under the invoice's issuance ID: a fresh, single-use ID
    // removed from `invoices` above, so `invoice_receipts.add` can never collide.
    let receipt = receipt::new_payment(
        customer,
        items,
        amount,
        now,
        invoice_id,
        payout_address,
        payment_type,
        loyalty,
        order_ref,
    );
    self.invoice_receipts.add(invoice_id, receipt);

    events::emit_invoice_paid(
        invoice_id,
        order_ref,
        customer,
        payout_address,
        payment_type,
        amount,
        loyalty,
        now,
        true,
    );
}

/// Permissionless cleanup of an expired invoice.
///
/// No balance is held by the invoice (customer funds stay in their Account until
/// settlement), so this is just removal + event. Emits `InvoiceCanceled`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `invoice_id`: Issuance id of the open invoice to cancel.
/// - `clock`: System clock (for expiry).
///
/// #### Aborts
/// - `EInvoiceNotFound` if no open invoice with `invoice_id` is stored.
/// - `ENotExpired` if the invoice has not yet expired.
public fun cancel_invoice(self: &mut Merchant, invoice_id: ID, clock: &Clock) {
    assert!(self.invoices.contains(invoice_id), EInvoiceNotFound);

    let (payout_address, payment_type, _items, amount, _loyalty, order_ref, expires_at_ms) = self
        .invoices
        .remove(invoice_id)
        .unpack();

    assert!(clock.timestamp_ms() >= expires_at_ms, ENotExpired);

    events::emit_invoice_canceled(invoice_id, payout_address, payment_type, amount, order_ref);
}

/// Customer creates a voucher with a locked `Balance<LOYALTY>`.
///
/// Prices each line by snapshotting the variant's current `loyalty_price`, asserts
/// the unlocked amount matches the items' total, resolves the unlock request into
/// a `Balance<LOYALTY>`, and stores the `Voucher` under a freshly minted ID (the
/// QR value). Emits `VoucherCreated`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `unlock_req`: Customer-approved `unlock_funds` request whose amount equals
///   the items' total `loyalty_price`. Resolved into a locked `Balance<LOYALTY>`.
/// - `policy_loyalty`: Shared `Policy<Balance<LOYALTY>>` consulted by
///   `unlock_funds::resolve_balance` to validate the request's approvals.
/// - `listing_variant_ids`: Variants to redeem against, same length as `quantities`.
/// - `quantities`: Per-variant quantities; each must be non-zero.
/// - `redeem_hash`: 32-byte blake2b256 commitment to a customer-chosen secret.
///   The preimage is required at `redeem` time.
/// - `clock`: System clock (for expiry computation).
/// - `ctx`: Transaction context (used to mint the voucher's fresh id).
///
/// #### Returns
/// - The issuance ID (the `Table` key and QR value).
///
/// #### Aborts
/// - `ENoItems` if `listing_variant_ids` is empty.
/// - `EItemsTooMany` if `listing_variant_ids.length() > MAX_INVOICE_ITEMS`.
/// - `ELengthMismatch` if the two vectors differ in length.
/// - `EZeroAmount` if the unlocked amount is zero.
/// - `EInvalidAmount` if the unlocked amount differs from the items' total.
/// - `EZeroQuantity` / `ENoLoyaltyPrice` / `EVariantNotFound` / `EListingInactive`
///   for catalog/price problems.
/// - `EBadHashLength` if `redeem_hash` is not 32 bytes (blake2b256 digest).
///
/// #### Hashlock authorization
/// `redeem_hash` is a 32-byte blake2b256 commitment to a customer-chosen
/// secret preimage. The customer keeps the preimage off-chain (e.g. browser
/// localStorage) and reveals it at the till via the voucher QR. `redeem`
/// requires the matching preimage, so `CashierRole` alone — even when armed
/// with the publicly-emitted `voucher_id`, cannot sweep vouchers without
/// the customer also revealing the preimage. See `merchant::redeem`.
public fun create_voucher(
    self: &mut Merchant,
    mut unlock_req: Request<UnlockFunds<Balance<LOYALTY>>>,
    policy_loyalty: &Policy<Balance<LOYALTY>>,
    listing_variant_ids: vector<ID>,
    quantities: vector<u64>,
    redeem_hash: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(!listing_variant_ids.is_empty(), ENoItems);
    assert!(listing_variant_ids.length() <= MAX_INVOICE_ITEMS, EItemsTooMany);
    assert!(listing_variant_ids.length() == quantities.length(), ELengthMismatch);
    assert!(redeem_hash.length() == 32, EBadHashLength);

    // Take and validate customer account and funds.
    let customer = unlock_req.data().owner();
    let amount = unlock_req.data().funds().value();
    assert!(amount > 0, EZeroAmount);

    // Combine and validate active items and quantities.
    let items = listing_variant_ids.zip_map!(
        quantities,
        |vid, qty| self.price_loyalty_item(vid, qty),
    );
    assert!(amount == receipt::compute_total(&items), EInvalidAmount);

    // Cannot overflow: `config::new` caps the TTL at `MAX_TTL_MS` (7 days), far below u64.
    let expires_at_ms = clock.timestamp_ms() + self.config.voucher_ttl_ms();

    // Extract funds from customer's PAS account and lock them in the voucher.
    unlock_req.approve(loyalty::new_redeem_unlock_approval());
    let funds: Balance<LOYALTY> = unlock_funds::resolve(unlock_req, policy_loyalty);

    let voucher = redemption::new(customer, items, funds, expires_at_ms, redeem_hash);

    let id = object::id_from_address(ctx.fresh_object_address());
    self.vouchers.add(id, voucher);

    events::emit_voucher_created(id);

    id
}

/// Permissionless cleanup after expiry - deposits the locked balance back into
/// the customer's PAS Account. Emits `VoucherCanceled`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `voucher_id`: Issuance id of the open voucher to cancel.
/// - `customer_loyalty_account`: PAS Account that receives the refunded LOYALTY.
///   Its owner must equal the voucher's `customer`.
/// - `clock`: System clock (for expiry).
///
/// #### Aborts
/// - `EVoucherNotFound` if no open voucher with `voucher_id` is stored.
/// - `ENotExpired` if the voucher has not yet expired.
/// - `EWrongCustomer` if the account owner is not the voucher's customer.
public fun cancel_voucher(
    self: &mut Merchant,
    voucher_id: ID,
    customer_loyalty_account: &Account,
    clock: &Clock,
) {
    assert!(self.vouchers.contains(voucher_id), EVoucherNotFound);

    let (customer, _items, funds, expires_at_ms, _redeem_hash) = self
        .vouchers
        .remove(voucher_id)
        .unpack();

    // Validate voucher's expiration time and customer's loyalty account.
    assert!(clock.timestamp_ms() >= expires_at_ms, ENotExpired);
    assert!(customer_loyalty_account.owner() == customer, EWrongCustomer);

    let amount = funds.value();
    events::emit_voucher_canceled(voucher_id, customer, amount);

    // Deposit funds back to the customer.
    customer_loyalty_account.deposit_balance(funds);
}

// === View Functions ===

/// Object ID of the shared `Merchant`.
public fun id(self: &Merchant): ID { object::id(self) }

/// Display name (mutable via `update_display`).
public fun name(self: &Merchant): &String { &self.name }

/// Optional logo URL (mutable via `update_display`).
public fun logo_url(self: &Merchant): &Option<String> { &self.logo_url }

/// Payout address — where customer stablecoin lands on `pay`. Delegates to
/// `Config.payout_address`.
public fun payout_address(self: &Merchant): address { self.config.payout_address() }

/// `TypeName` of the only stablecoin currency this merchant accepts (mirrors
/// the phantom `C`). Delegates to `Config.accepted_payment_type`.
public fun accepted_payment_type(self: &Merchant): TypeName {
    self.config.accepted_payment_type()
}

/// ID of the embedded `TreasuryCap<LOYALTY>`. Off-chain indexers only —
/// the cap itself stays inside `self.loyalty` and is never publicly borrowable.
public fun loyalty_treasury_cap_id(self: &Merchant): ID { self.loyalty.treasury_cap_id() }

/// ID of the embedded `PolicyCap<Balance<LOYALTY>>`. Off-chain indexers only —
/// the cap is auth for PAS policy mutations, so it must not leak by reference.
public fun loyalty_policy_cap_id(self: &Merchant): ID { self.loyalty.policy_cap_id() }

/// ID of the shared `Policy<Balance<LOYALTY>>` for the loyalty currency.
public fun loyalty_policy_id(self: &Merchant): ID { self.loyalty.policy_id() }

/// Current total supply of `LOYALTY` (mints minus burns). View-only.
public fun loyalty_supply(self: &Merchant): u64 { self.loyalty.supply() }

/// Current full merchant `Config` — payout, accepted type, decimals, rate, TTLs.
public fun config(self: &Merchant): &Config { &self.config }

/// Look up a stored `Listing` by ID.
///
/// #### Parameters
/// - `self`: The merchant to read.
/// - `id`: ID of the listing to look up.
///
/// #### Returns
/// - Reference to the matching `Listing`.
///
/// #### Aborts
/// - `EListingNotFound` if no listing with `id` is stored.
public fun listing(self: &Merchant, id: ID): &Listing {
    assert!(self.listings.contains(id), EListingNotFound);

    self.listings.borrow(id)
}

/// Resolve a listing variant from the catalog by ID, going through
/// `variant_index` to find its parent listing.
///
/// #### Parameters
/// - `self`: The merchant to read.
/// - `listing_variant_id`: ID of the variant to resolve.
///
/// #### Returns
/// - Reference to the matching `Variant`.
///
/// #### Aborts
/// - `EVariantNotFound` if the variant is not registered.
public fun listing_variant(self: &Merchant, listing_variant_id: &ID): &Variant {
    assert!(self.variant_index.contains(*listing_variant_id), EVariantNotFound);

    let listing_id = *self.variant_index.borrow(*listing_variant_id);
    self.listings.borrow(listing_id).variant(listing_variant_id)
}

/// Like `listing_variant`, but additionally asserts the parent listing is `active`.
///
/// Used at issuance time by `create_invoice` / `create_voucher` (via the private
/// `price_item` / `price_loyalty_item` helpers) so inactive listings can't be sold
/// or redeemed against. Also useful to clients for pre-flight checks before
/// submitting an issuance call.
///
/// #### Parameters
/// - `self`: The merchant to read.
/// - `listing_variant_id`: ID of the variant to resolve.
///
/// #### Returns
/// - Reference to the matching `Variant` on an active listing.
///
/// #### Aborts
/// - `EVariantNotFound` if the variant is not registered.
/// - `EListingInactive` if the parent listing is not active.
public fun active_listing_variant(self: &Merchant, listing_variant_id: &ID): &Variant {
    assert!(self.variant_index.contains(*listing_variant_id), EVariantNotFound);

    // Lookup matching listing by variant index.
    let listing_id = *self.variant_index.borrow(*listing_variant_id);
    let listing = self.listings.borrow(listing_id);
    assert!(listing.active(), EListingInactive);

    listing.variant(listing_variant_id)
}

/// Look up an open `Invoice` by its issuance ID.
///
/// #### Aborts
/// - `EInvoiceNotFound` if no open invoice with `id` is stored.
public fun invoice(self: &Merchant, id: ID): &Invoice {
    assert!(self.invoices.contains(id), EInvoiceNotFound);

    self.invoices.borrow(id)
}

/// Look up an open `Voucher` by its issuance ID.
///
/// #### Aborts
/// - `EVoucherNotFound` if no open voucher with `id` is stored.
public fun voucher(self: &Merchant, id: ID): &Voucher {
    assert!(self.vouchers.contains(id), EVoucherNotFound);

    self.vouchers.borrow(id)
}

/// Look up a stored payment `Receipt<Payment>` by the settled invoice ID.
///
/// Customer-scoped history is not an on-chain query - `Receipt.customer` is a
/// value field, not a key. Index the `InvoicePaid` event off-chain for
/// per-customer history.
///
/// #### Aborts
/// - `EReceiptNotFound` if no payment receipt with `id` is stored.
public fun invoice_receipt(self: &Merchant, id: ID): &Receipt<Payment> {
    assert!(self.invoice_receipts.contains(id), EReceiptNotFound);

    self.invoice_receipts.borrow(id)
}

/// Look up a stored redemption `Receipt<Redemption>` by the redeemed voucher ID.
///
/// Index the `VoucherRedeemed` event off-chain for per-customer history.
///
/// #### Aborts
/// - `EReceiptNotFound` if no redemption receipt with `id` is stored.
public fun voucher_receipt(self: &Merchant, id: ID): &Receipt<Redemption> {
    assert!(self.voucher_receipts.contains(id), EReceiptNotFound);

    self.voucher_receipts.borrow(id)
}

// === Admin Functions ===

/// Update display name and logo URL.
///
/// Gated by `MerchantRole`. Emits `DisplayUpdated`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `MerchantRole` authorization.
/// - `name`: The new display name. Must be non-empty.
/// - `logo`: The new optional logo URL.
///
/// #### Aborts
/// - `EEmptyName` if `name` is empty.
/// - `EDisplayUnchanged` if both `name` and `logo` already match the current values.
public fun update_display(
    self: &mut Merchant,
    _auth: &Auth<MerchantRole>,
    name: String,
    logo: Option<String>,
) {
    assert!(!name.is_empty(), EEmptyName);
    assert!(&self.name != &name || &self.logo_url != &logo, EDisplayUnchanged);

    self.name = name;
    self.logo_url = logo;

    events::emit_display_updated();
}

/// Replace the merchant's full `Config` — payout address, accepted payment type,
/// decimals, loyalty rate, TTLs.
///
/// Build the new value via `config::new<C>(&currency, ...)` and pass it in. The
/// replacement is effective for subsequent settlements only; invoices already
/// issued snapshot `payout_address`/`payment_type`/`amount`/`loyalty` at creation
/// and are unaffected. Gated by `MerchantRole`. Emits `ConfigUpdated`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `MerchantRole` authorization.
/// - `config`: The replacement `Config`.
///
/// #### Aborts
/// - `EConfigUnchanged` if the new config equals the current one.
public fun update_config(self: &mut Merchant, _auth: &Auth<MerchantRole>, config: Config) {
    assert!(&self.config != &config, EConfigUnchanged);

    self.config = config;

    events::emit_config_updated();
}

/// Take ownership of a caller-built `Listing` and store it under its own ID.
///
/// Every variant already on the listing is registered in `variant_index` so
/// checkout can resolve it from the variant ID alone. Gated by
/// `CatalogManagerRole`. Emits `ListingAdded`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `CatalogManagerRole` authorization.
/// - `listing`: The listing to store.
///
/// #### Returns
/// - The stored listing's ID.
///
/// #### Aborts
/// - Aborts (via `Table::add`) if the listing ID or any of its variant IDs
///   already exist on the merchant.
public fun add_listing(
    self: &mut Merchant,
    _auth: &Auth<CatalogManagerRole>,
    listing: Listing,
): ID {
    let id = listing.id();

    // Add listing's variants to variant lookup table.
    listing.variants().keys().do!(|vid| {
        self.variant_index.add(vid, id);
    });
    self.listings.add(id, listing);

    events::emit_listing_added(id);

    id
}

/// Pull a `Listing` out of the merchant.
///
/// Every variant on the removed listing is also dropped from `variant_index`.
/// Gated by `CatalogManagerRole`. Emits `ListingRemoved`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `CatalogManagerRole` authorization.
/// - `id`: ID of the listing to remove.
///
/// #### Aborts
/// - `EListingNotFound` if no listing with `id` is stored.
public fun remove_listing(self: &mut Merchant, _auth: &Auth<CatalogManagerRole>, id: ID) {
    assert!(self.listings.contains(id), EListingNotFound);

    let removed = self.listings.remove(id);

    // Remove listing's variants from variant lookup table.
    removed.variants().keys().do!(|vid| {
        let _: ID = self.variant_index.remove(vid);
    });

    events::emit_listing_removed(id);
}

/// Toggle a listing's `active` flag.
///
/// Gated by `CatalogManagerRole`. Emits `ListingStatusChanged`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `CatalogManagerRole` authorization.
/// - `listing_id`: ID of the listing to toggle.
/// - `active`: The new active state.
///
/// #### Aborts
/// - `EListingNotFound` if no listing with `listing_id` is stored.
/// - `EActiveStateUnchanged` if `active` already matches the listing's state.
public fun set_listing_status(
    self: &mut Merchant,
    _auth: &Auth<CatalogManagerRole>,
    listing_id: ID,
    active: bool,
) {
    assert!(self.listings.contains(listing_id), EListingNotFound);

    self.listings.borrow_mut(listing_id).set_active(active);

    events::emit_listing_status_changed(listing_id, active);
}

/// Insert a variant into an existing listing and return its ID.
///
/// The new variant is also registered in `variant_index`. Gated by
/// `CatalogManagerRole`. Emits `VariantAdded`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `CatalogManagerRole` authorization.
/// - `listing_id`: ID of the parent listing.
/// - `variant`: The variant to insert.
///
/// #### Returns
/// - The inserted variant's ID.
///
/// #### Aborts
/// - `EListingNotFound` if no listing with `listing_id` is stored.
/// - Aborts (via `vec_map::insert`) if the variant's `id` already exists.
public fun add_listing_variant(
    self: &mut Merchant,
    _auth: &Auth<CatalogManagerRole>,
    listing_id: ID,
    variant: Variant,
): ID {
    assert!(self.listings.contains(listing_id), EListingNotFound);

    // Add listing's variant to listing and to listing variant's lookup table.
    let id = self.listings.borrow_mut(listing_id).add_variant(variant);
    self.variant_index.add(id, listing_id);

    events::emit_variant_added(listing_id, id);

    id
}

/// Remove a variant by ID from its listing.
///
/// The owning listing is resolved via `variant_index` - no separate
/// `listing_id` argument needed. Gated by `CatalogManagerRole`. Emits
/// `VariantRemoved`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `CatalogManagerRole` authorization.
/// - `variant_id`: ID of the variant to remove.
///
/// #### Aborts
/// - `EVariantNotFound` if the variant is not registered.
public fun remove_listing_variant(
    self: &mut Merchant,
    _auth: &Auth<CatalogManagerRole>,
    variant_id: ID,
) {
    assert!(self.variant_index.contains(variant_id), EVariantNotFound);

    // Remove listing's variant from listing and from listing variant's lookup table.
    let listing_id = self.variant_index.remove(variant_id);
    self.listings.borrow_mut(listing_id).remove_variant(variant_id);

    events::emit_variant_removed(listing_id, variant_id);
}

// === Settlement Functions ===

/// Merchant issues an invoice from parallel `listing_variant_ids` + `quantities`.
///
/// Each pair is priced by snapshotting the variant's current stablecoin price.
/// The total `amount`, the `loyalty` reward, the accepted `payment_type`, and the
/// `expires_at_ms` (from `Config.invoice_ttl_ms`) are all snapshotted, and the
/// resulting `Invoice` is stored in `Merchant.invoices` under a freshly minted ID
/// (the QR value). Gated by `CashierRole`. Emits `InvoiceCreated`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `CashierRole` authorization.
/// - `listing_variant_ids`: Variants to bill, same length as `quantities`.
/// - `quantities`: Per-variant quantities; each must be non-zero.
/// - `order_ref`: Opaque merchant-supplied tag (e.g. POS order number). Echoed
///   on the receipt and the `InvoicePaid` event.
/// - `clock`: System clock (for expiry computation).
/// - `ctx`: Transaction context (used to mint the invoice's fresh id).
///
/// #### Returns
/// - The issuance ID (the `Table` key and QR value).
///
/// #### Aborts
/// - `ENoItems` if `listing_variant_ids` is empty.
/// - `ELengthMismatch` if the two vectors differ in length.
/// - `EItemsTooMany` if `listing_variant_ids.length() > MAX_INVOICE_ITEMS`.
/// - `EZeroQuantity` if any quantity is zero.
/// - `EVariantNotFound` / `EListingInactive` if a variant is unregistered or its
///   parent listing is inactive.
/// - `EOrderRefTooLong` if `order_ref` is longer than `MAX_ORDER_REF_LEN` bytes.
public fun create_invoice(
    self: &mut Merchant,
    _auth: &Auth<CashierRole>,
    listing_variant_ids: vector<ID>,
    quantities: vector<u64>,
    order_ref: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(!listing_variant_ids.is_empty(), ENoItems);
    assert!(listing_variant_ids.length() <= MAX_INVOICE_ITEMS, EItemsTooMany);
    assert!(listing_variant_ids.length() == quantities.length(), ELengthMismatch);
    assert!(order_ref.length() <= MAX_ORDER_REF_LEN, EOrderRefTooLong);

    let items = listing_variant_ids.zip_map!(quantities, |vid, qty| self.price_item(vid, qty));
    // Amount should not be zero, since individual prices and quantities enforced to be non-zero.
    let amount = receipt::compute_total(&items);
    let loyalty = self.config.compute_loyalty(amount);
    // Cannot overflow: `config::new` caps the TTL at `MAX_TTL_MS` (7 days), far below u64.
    let expires_at_ms = clock.timestamp_ms() + self.config.invoice_ttl_ms();

    let invoice = payment::new(
        self.config.payout_address(),
        self.config.accepted_payment_type(),
        items,
        amount,
        loyalty,
        order_ref,
        expires_at_ms,
    );

    let id = object::id_from_address(ctx.fresh_object_address());
    self.invoices.add(id, invoice);

    events::emit_invoice_created(id);

    id
}

/// Merchant redeems an open voucher.
///
/// Burns the locked `Balance<LOYALTY>` via the merchant's `TreasuryCap<LOYALTY>`,
/// removes the voucher, stores a `Receipt` keyed by `voucher_id`, and emits
/// `VoucherRedeemed`. Gated by both:
///   - `CashierRole` — the till operator authorizes settlement, AND
///   - the customer's preimage matching `voucher.redeem_hash` — proves the
///     redeemer holds the secret the customer chose at issuance.
///
/// `CashierRole` alone is no longer sufficient: even a cashier who observes
/// `voucher_id` from the public `VoucherCreated` event cannot redeem without
/// the customer also revealing the preimage (typically via the QR shown at
/// the till). The preimage is opaque random bytes the customer's dApp
/// generates client-side and stores locally — it never appears on chain
/// until reveal time.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `CashierRole` authorization.
/// - `voucher_id`: Issuance id of the open voucher being redeemed.
/// - `preimage`: 32-byte secret matching the voucher's `redeem_hash` commitment.
/// - `clock`: System clock (for expiry).
///
/// #### Aborts
/// - `EVoucherNotFound` if no open voucher with `voucher_id` is stored.
/// - `EVoucherExpired` if the voucher has expired.
/// - `EWrongPreimage` if `blake2b256(preimage) != voucher.redeem_hash`.
public fun redeem(
    self: &mut Merchant,
    _auth: &Auth<CashierRole>,
    voucher_id: ID,
    preimage: vector<u8>,
    clock: &Clock,
) {
    assert!(self.vouchers.contains(voucher_id), EVoucherNotFound);

    let (customer, items, funds, expires_at_ms, redeem_hash) = self
        .vouchers
        .remove(voucher_id)
        .unpack();

    // Validate voucher's expiration time and submitted preimage.
    let now = clock.timestamp_ms();
    assert!(now < expires_at_ms, EVoucherExpired);
    assert!(hash::blake2b256(&preimage) == redeem_hash, EWrongPreimage);

    // Store the receipt under the voucher's issuance ID: a fresh, single-use ID
    // removed from `vouchers` above, so `voucher_receipts.add` can never collide.
    let amount = funds.value();
    let receipt = receipt::new_redemption(customer, items, amount, now, voucher_id);
    self.voucher_receipts.add(voucher_id, receipt);

    // Decrease loyalty supply.
    self.loyalty.decrease_supply(funds);

    events::emit_voucher_redeemed(voucher_id, customer, amount, now);
}

/// Reclaim storage by pruning the listed payment receipts.
///
/// Receipts are redundant with the permanent `InvoicePaid` event stream, so
/// pruning loses no canonical history - it only frees the merchant's storage
/// deposit (refunded to the caller). The merchant computes which receipts to drop
/// off-chain (a `Table` can't be iterated on-chain) and passes their `ids`. Gated
/// by `MerchantRole`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `MerchantRole` authorization.
/// - `ids`: Receipt IDs (settled invoice IDs) to prune.
///
/// #### Aborts
/// - `EReceiptNotFound` if any `id` has no stored payment receipt.
public fun prune_invoice_receipts(
    self: &mut Merchant,
    _auth: &Auth<MerchantRole>,
    ids: vector<ID>,
) {
    ids.do!(|id| {
        assert!(self.invoice_receipts.contains(id), EReceiptNotFound);
        self.invoice_receipts.remove(id).destroy();
    });
}

/// Reclaim storage by pruning the listed redemption receipts.
///
/// Mirror of `prune_invoice_receipts` for the `VoucherRedeemed` side. Gated by
/// `MerchantRole`.
///
/// #### Parameters
/// - `self`: The merchant to mutate.
/// - `_auth`: `MerchantRole` authorization.
/// - `ids`: Receipt IDs (redeemed voucher IDs) to prune.
///
/// #### Aborts
/// - `EReceiptNotFound` if any `id` has no stored redemption receipt.
public fun prune_voucher_receipts(
    self: &mut Merchant,
    _auth: &Auth<MerchantRole>,
    ids: vector<ID>,
) {
    ids.do!(|id| {
        assert!(self.voucher_receipts.contains(id), EReceiptNotFound);
        self.voucher_receipts.remove(id).destroy();
    });
}

// === Private Functions ===

/// Price one stablecoin line by snapshotting the variant's current price from
/// the catalog (asserting the parent listing is active).
///
/// #### Aborts
/// - `EZeroQuantity` if `quantity` is zero.
/// - `EVariantNotFound` / `EListingInactive` if the variant is unregistered or
///   its parent listing is inactive.
fun price_item(self: &Merchant, variant_id: ID, quantity: u64): Item {
    assert!(quantity > 0, EZeroQuantity);

    let price = self.active_listing_variant(&variant_id).price();
    receipt::new_item(variant_id, quantity, price)
}

/// Price one loyalty line by snapshotting the variant's current `loyalty_price`.
///
/// #### Aborts
/// - `EZeroQuantity` if `quantity` is zero.
/// - `ENoLoyaltyPrice` if the variant's `loyalty_price` is `None`.
/// - `EVariantNotFound` / `EListingInactive` if the variant is unregistered or
///   its parent listing is inactive.
fun price_loyalty_item(self: &Merchant, variant_id: ID, quantity: u64): Item {
    assert!(quantity > 0, EZeroQuantity);

    let price = self
        .active_listing_variant(&variant_id)
        .loyalty_price()
        .destroy_or!(abort ENoLoyaltyPrice);
    receipt::new_item(variant_id, quantity, price)
}

// === Test-Only Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(MERCHANT {}, ctx);
}
