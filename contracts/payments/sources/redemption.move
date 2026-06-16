/// Voucher — customer-issued redemption intent with locked `Balance<LOYALTY>`,
/// stored as a value in `Merchant`.
///
/// This module only defines the `Voucher` data type plus a merchant-agnostic
/// constructor (`new`) and destructurer (`unpack`). Like `payment`, it has NO
/// dependency on `merchant` (which would cycle, since `Merchant` stores
/// `Table<ID, Voucher>`). All merchant-aware logic — unlock resolution,
/// redemption (burn), and cancellation (refund) — lives in `merchant`.
module openzeppelin_payments::redemption;

use openzeppelin_payments::loyalty::LOYALTY;
use openzeppelin_payments::receipt::Item;
use sui::balance::Balance;

// === Structs ===

/// Customer-issued voucher with a locked `Balance<LOYALTY>`. Stored in
/// `Merchant.vouchers` keyed by a freshly minted ID; that ID is surfaced via QR
/// for the merchant to scan and redeem.
///
/// `store`-only (no `key`): identity is the `Table` key, not an object UID. No
/// `drop` either — it holds `Balance<LOYALTY>`, which is a linear resource.
public struct Voucher has store {
    /// Owner of the unlock request that funded this voucher. Recipient of the
    /// `Receipt` on `redeem` and of the returned balance on `cancel`.
    customer: address,
    /// Line items with snapshot LOYALTY prices.
    items: vector<Item>,
    /// LOYALTY balance locked inside the voucher. Burned on `redeem`, returned
    /// to the customer's PAS Account on `cancel`.
    funds: Balance<LOYALTY>,
    /// Expiry timestamp (ms). Past this point `redeem` aborts and `cancel`
    /// becomes permissionless.
    expires_at_ms: u64,
}

// === Package Functions ===

/// Merchant-agnostic constructor. `merchant::create_voucher` resolves prices,
/// extracts the locked balance, and snapshots fields, then calls this.
public(package) fun new(
    customer: address,
    items: vector<Item>,
    funds: Balance<LOYALTY>,
    expires_at_ms: u64,
): Voucher {
    Voucher { customer, items, funds, expires_at_ms }
}

/// Consume the voucher and return its fields (including the locked balance).
/// `Voucher` has no `drop`, so `merchant` destructures it through this on
/// `redeem` / `cancel`.
public(package) fun unpack(self: Voucher): (address, vector<Item>, Balance<LOYALTY>, u64) {
    let Voucher { customer, items, funds, expires_at_ms } = self;
    (customer, items, funds, expires_at_ms)
}

// === View Functions ===

/// Address that owns the locked LOYALTY balance (recipient on `cancel`).
public fun customer(self: &Voucher): address { self.customer }

/// Line items with snapshot LOYALTY prices.
public fun items(self: &Voucher): &vector<Item> { &self.items }

/// LOYALTY units locked inside the voucher.
public fun amount(self: &Voucher): u64 { self.funds.value() }

/// Expiry timestamp (ms).
public fun expires_at_ms(self: &Voucher): u64 { self.expires_at_ms }
