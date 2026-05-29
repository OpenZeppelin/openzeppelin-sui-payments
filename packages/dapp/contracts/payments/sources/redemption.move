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
///   voucher    = redemption::new(merchant, unlock_req, policy_loyalty, ids, qtys, &clock, ctx)
///   redemption::share(voucher)
///
/// Merchant POS flow (after scanning the customer's QR):
///   redemption::redeem(voucher, merchant, &cap, &clock)
///
/// Cleanup (permissionless after expiry):
///   redemption::cancel(voucher, customer_LOY_account, &clock)
///   — balance returns to the customer's Account.
module openzeppelin_payments::redemption;

use openzeppelin_payments::events;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant::{Merchant, MerchantCap};
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
const EZeroAmount: vector<u8> = b"Voucher amount must be greater than zero";
#[error(code = 1)]
const ENotExpired: vector<u8> = b"Voucher has not yet expired";
#[error(code = 2)]
const EVoucherExpired: vector<u8> = b"Voucher has expired";
#[error(code = 3)]
const EWrongCustomer: vector<u8> = b"Account owner does not match Voucher customer";
#[error(code = 4)]
const EInvalidAmount: vector<u8> = b"Voucher amount must be equal to total redeemed amount";

// === Structs ===

/// Customer-issued voucher with locked `Balance<LOYALTY>`. The package's single
/// Merchant can `redeem` to burn the locked balance. After `expires_at_ms`, anyone
/// can `cancel` to return the locked balance to the customer (identified by `customer`).
///
/// NOTE: No `merchant_id` field: the package's single-Merchant invariant means there's
/// only one Merchant any Voucher could be against.
public struct Voucher has key {
    id: UID,
    customer: address,
    items: vector<Item>,
    funds: Balance<LOYALTY>,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Customer creates a voucher. Extracts the LOYALTY balance via the unlock request
/// (which the customer built using their PAS `Auth`), resolves it through the
/// merchant's loyalty `Policy` with our package-private `RedeemUnlockApproval`
/// witness, and stashes the resulting `Balance<LOYALTY>` inside the Voucher.
/// `expires_at_ms` is derived from the merchant's `Config.voucher_ttl_ms`.
public fun new(
    merchant: &Merchant,
    mut unlock_req: Request<UnlockFunds<Balance<LOYALTY>>>,
    policy_loyalty: &Policy<Balance<LOYALTY>>,
    listing_variant_ids: vector<ID>,
    quantities: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Voucher {
    let customer = unlock_req.data().owner();
    let amount = unlock_req.data().funds().value();
    assert!(amount > 0, EZeroAmount);

    let items = listing_variant_ids.zip_map!(quantities, |vid, qty| {
        receipt::new_item(merchant, vid, qty)
    });
    assert!(amount == receipt::compute_total(&items), EInvalidAmount);

    unlock_req.approve(loyalty::new_redeem_unlock_approval());
    let funds: Balance<LOYALTY> = unlock_funds::resolve(unlock_req, policy_loyalty);

    Voucher {
        id: object::new(ctx),
        customer,
        items,
        funds,
        expires_at_ms: clock.timestamp_ms() + merchant.config().voucher_ttl_ms(),
    }
}

/// Share the voucher. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` is restricted to this module.
public fun share(voucher: Voucher) {
    transfer::share_object(voucher);
}

/// Merchant redeems the voucher: burns the locked `Balance<LOYALTY>` via the
/// merchant's `TreasuryCap<LOYALTY>`, destroys the voucher, mints a soulbound
/// `RedemptionReceipt` for the customer, and emits `VoucherRedeemed`.
public fun redeem(
    voucher: Voucher,
    _cap: &MerchantCap,
    merchant: &mut Merchant,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let voucher_id = object::id(&voucher);
    let merchant_id = object::id(merchant);
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

    events::emit_voucher_redeemed(voucher_id, merchant_id, customer, amount, now);
}

/// Permissionless cleanup after expiry — deposits the locked balance back into the
/// customer's PAS Account. Prevents griefing by an inactive merchant (whose refusal
/// to redeem would otherwise strand the customer's loyalty until expiry).
public fun cancel(voucher: Voucher, customer_loyalty_account: &Account, clock: &Clock) {
    assert!(clock.timestamp_ms() >= voucher.expires_at_ms, ENotExpired);
    assert!(customer_loyalty_account.owner() == voucher.customer, EWrongCustomer);

    let Voucher { id, funds, .. } = voucher;
    customer_loyalty_account.deposit_balance(funds);
    id.delete();
}

// === View Functions ===

public fun customer(self: &Voucher): address { self.customer }

public fun amount(self: &Voucher): u64 { self.funds.value() }

public fun expires_at_ms(self: &Voucher): u64 { self.expires_at_ms }
