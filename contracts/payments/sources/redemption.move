/// Redemption — customer-issued `Voucher` with locked `Balance<LOYALTY>` + merchant
/// settles by burning.
///
/// Customer creates the voucher first: their LOYALTY balance is extracted from their
/// PAS Account and locked inside the Voucher object. The customer then shows a QR
/// encoding the voucher's object ID to the merchant. The merchant calls `redeem` to
/// burn the locked balance. After expiry, anyone can call `cancel` to return the
/// locked balance to the customer's PAS Account.
///
/// Customer wallet flow:
///   auth       = account::new_auth(&ctx)
///   unlock_req = customer_LOY.unlock_balance<LOYALTY>(&auth, amount, &ctx)
///   voucher    = redemption::new(merchant, unlock_req, policy_loyalty, ids, quantities, &clock, ctx)
///   redemption::share(voucher)
///
/// Merchant POS flow (after scanning the customer's QR):
///   redemption::redeem(voucher, &auth, merchant, &clock, ctx)
///   — gated by `Auth<CashierRole>`.
///
/// Cleanup (permissionless after expiry):
///   redemption::cancel(voucher, customer_LOY_account, &clock)
///   — balance returns to the customer's Account.
module openzeppelin_payments::redemption;

use openzeppelin_access::access_control::Auth;
use openzeppelin_payments::events;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant::{Merchant, CashierRole};
use openzeppelin_payments::receipt::{Self, Item};
use pas::account::Account;
use pas::policy::Policy;
use pas::request::Request;
use pas::unlock_funds::{Self, UnlockFunds};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin;

// === Errors ===

#[error(code = 0)]
const EZeroAmount: vector<u8> = "Voucher amount must be greater than zero";
#[error(code = 1)]
const ENotExpired: vector<u8> = "Voucher has not yet expired";
#[error(code = 2)]
const EVoucherExpired: vector<u8> = "Voucher has expired";
#[error(code = 3)]
const EWrongCustomer: vector<u8> = "Account owner does not match Voucher customer";
#[error(code = 4)]
const EInvalidAmount: vector<u8> = "Voucher amount must be equal to total redeemed amount";
#[error(code = 5)]
const ENoItems: vector<u8> = "Voucher must include at least one item";
#[error(code = 6)]
const ELengthMismatch: vector<u8> = "listing_variant_ids and quantities must have the same length";

// === Structs ===

/// Customer-issued voucher with locked `Balance<LOYALTY>`. The package's single
/// Merchant can `redeem` to burn the locked balance. After `expires_at_ms`, anyone
/// can `cancel` to return the locked balance to the customer (identified by `customer`).
///
/// NOTE: No `merchant_id` field: the package's single-Merchant invariant means there's
/// only one Merchant any Voucher could be against.
public struct Voucher has key {
    /// Object ID. Surfaced via QR for the merchant to scan and look up the
    /// shared object.
    id: UID,
    /// Owner of the unlock request that funded this voucher. Recipient of the
    /// soulbound `Receipt<Redemption>` on `redeem`, and of the returned balance
    /// on `cancel`.
    customer: address,
    /// Line items with snapshot LOYALTY prices (see `receipt::new_loyalty_item`).
    items: vector<Item>,
    /// LOYALTY balance locked inside the voucher. Burned on `redeem`,
    /// returned to the customer's PAS Account on `cancel`.
    funds: Balance<LOYALTY>,
    /// Expiry timestamp (ms). Past this point `redeem` aborts and `cancel`
    /// becomes permissionless.
    expires_at_ms: u64,
}

// === Public Functions ===

/// Customer creates a voucher.
///
/// Extracts the LOYALTY balance via the unlock request (which the customer built
/// using their PAS `Auth`), resolves it through the merchant's loyalty `Policy`
/// with the package-private `RedeemUnlockApproval` witness, and stashes the
/// resulting `Balance<LOYALTY>` inside the Voucher. `expires_at_ms` is derived
/// from the merchant's `Config.voucher_ttl_ms`. Emits `VoucherCreated`.
///
/// #### Parameters
/// - `merchant`: The merchant whose catalog and config are read.
/// - `unlock_req`: The customer's `UnlockFunds<Balance<LOYALTY>>` request.
/// - `policy_loyalty`: The PAS policy governing `Balance<LOYALTY>`.
/// - `listing_variant_ids`: Variant IDs being redeemed.
/// - `quantities`: Per-variant quantities, parallel to `listing_variant_ids`.
/// - `clock`: Clock used to compute `expires_at_ms`.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - The constructed `Voucher` (caller must `share` it).
///
/// #### Aborts
/// - `ENoItems` if `listing_variant_ids` is empty.
/// - `ELengthMismatch` if the two vectors differ in length.
/// - `EZeroAmount` if the unlocked amount is zero.
/// - `EInvalidAmount` if the unlocked amount differs from the items' total.
/// - `ENoLoyaltyPrice` / `EVariantNotFound` / `EListingInactive` (via
///   `receipt::new_loyalty_item`) for catalog/price problems.
public fun new(
    merchant: &Merchant,
    mut unlock_req: Request<UnlockFunds<Balance<LOYALTY>>>,
    policy_loyalty: &Policy<Balance<LOYALTY>>,
    listing_variant_ids: vector<ID>,
    quantities: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Voucher {
    assert!(!listing_variant_ids.is_empty(), ENoItems);
    assert!(listing_variant_ids.length() == quantities.length(), ELengthMismatch);

    // Take and validate customer account and funds.
    let customer = unlock_req.data().owner();
    let amount = unlock_req.data().funds().value();
    assert!(amount > 0, EZeroAmount);

    // Combine and validate active items and quantities.
    let items = listing_variant_ids.zip_map!(quantities, |vid, qty| {
        receipt::new_loyalty_item(merchant, vid, qty)
    });
    assert!(amount == receipt::compute_total(&items), EInvalidAmount);

    // Extract funds from customer's PAS account and lock them in voucher.
    unlock_req.approve(loyalty::new_redeem_unlock_approval());
    let funds: Balance<LOYALTY> = unlock_funds::resolve(unlock_req, policy_loyalty);

    let voucher = Voucher {
        id: object::new(ctx),
        customer,
        items,
        funds,
        expires_at_ms: clock.timestamp_ms() + merchant.config().voucher_ttl_ms(),
    };

    events::emit_voucher_created(object::id(&voucher));

    voucher
}

/// Share the voucher. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` is restricted to this module.
public fun share(voucher: Voucher) {
    transfer::share_object(voucher);
}

/// Merchant redeems the voucher.
///
/// Burns the locked `Balance<LOYALTY>` via the merchant's `TreasuryCap<LOYALTY>`,
/// destroys the voucher, mints a soulbound `Receipt<Redemption>` for the
/// customer, and emits `VoucherRedeemed`. Gated by `CashierRole`.
///
/// #### Parameters
/// - `voucher`: The voucher to redeem (consumed).
/// - `_auth`: `CashierRole` authorization.
/// - `merchant`: The merchant (mutated to burn supply).
/// - `clock`: Clock used to validate expiry and stamp the receipt.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EVoucherExpired` if the voucher has expired.
public fun redeem(
    voucher: Voucher,
    _auth: &Auth<CashierRole>,
    merchant: &mut Merchant,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let voucher_id = object::id(&voucher);
    let now = clock.timestamp_ms();

    assert!(now < voucher.expires_at_ms, EVoucherExpired);

    let Voucher { id, customer, items, funds, expires_at_ms: _ } = voucher;
    let amount = funds.value();

    balance::decrease_supply(
        coin::supply_mut(merchant.loyalty_mut().treasury_cap_mut()),
        funds,
    );
    id.delete();

    // Soulbound receipt to the customer
    receipt::transfer_redemption_receipt(voucher_id, items, amount, now, customer, ctx);

    events::emit_voucher_redeemed(voucher_id, customer, amount, now);
}

/// Permissionless cleanup after expiry — deposits the locked balance back into
/// the customer's PAS Account.
///
/// Prevents griefing by an inactive merchant (whose refusal to redeem would
/// otherwise strand the customer's loyalty until expiry). Emits `VoucherCanceled`.
///
/// #### Parameters
/// - `voucher`: The expired voucher to cancel (consumed).
/// - `customer_loyalty_account`: The customer's PAS account to refund into.
/// - `clock`: Clock used to verify the voucher has expired.
///
/// #### Aborts
/// - `ENotExpired` if the voucher has not yet expired.
/// - `EWrongCustomer` if the account owner is not the voucher's customer.
public fun cancel(voucher: Voucher, customer_loyalty_account: &Account, clock: &Clock) {
    assert!(clock.timestamp_ms() >= voucher.expires_at_ms, ENotExpired);
    assert!(customer_loyalty_account.owner() == voucher.customer, EWrongCustomer);

    let Voucher { id, customer, funds, .. } = voucher;

    events::emit_voucher_canceled(id.to_inner(), customer, funds.value());

    // Deposit funds back to customer.
    customer_loyalty_account.deposit_balance(funds);

    id.delete();
}

// === View Functions ===

/// Object ID of the shared `Voucher`.
public fun id(self: &Voucher): ID { object::id(self) }

/// Address that owns the locked LOYALTY balance (recipient on `cancel`).
public fun customer(self: &Voucher): address { self.customer }

/// Line items with snapshot LOYALTY prices.
public fun items(self: &Voucher): &vector<Item> { &self.items }

/// LOYALTY units locked inside the voucher.
public fun amount(self: &Voucher): u64 { self.funds.value() }

/// Expiry timestamp (ms). After this point `redeem` aborts with
/// `EVoucherExpired` and `cancel` becomes permissionless.
public fun expires_at_ms(self: &Voucher): u64 { self.expires_at_ms }
