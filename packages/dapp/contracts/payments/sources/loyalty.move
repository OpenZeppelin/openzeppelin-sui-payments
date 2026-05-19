/// Soulbound loyalty asset — a standard Sui Coin wrapped with a PAS `Policy<LOYALTY>`.
///
/// At init:
/// - Standard currency creation via `coin_registry::new_currency_with_otw` produces
///   `TreasuryCap<LOYALTY>` and `CoinMetadata<LOYALTY>`.
/// - PAS namespace + `Policy<LOYALTY>` are created. The policy registers approval
///   requirements only for `unlock_funds` (gated by a package-private `RedeemUnlockApproval`
///   witness this module produces). `send_funds` has no approvals registered → soulbound.
///   `clawback_funds` has no approvals registered → no clawback in v1.
/// - `TreasuryCap<LOYALTY>`, namespace ID, and policy ID get wired into `MerchantConfig`.
///
/// Mint (`public(package)`): standard `cap.mint_balance(amount)` → `account.deposit_balance(b)`.
/// Called by `payment` to mint earning loyalty into the customer's PAS Account.
///
/// Approval witness (`public(package) fun new_redeem_unlock_approval(): RedeemUnlockApproval`):
/// Only produced inside this module / friend modules. Used by `redemption::request_redeem`
/// to resolve an `unlock_funds` request and extract `Balance<LOYALTY>` for the Hold.
module openzeppelin_payments::loyalty;
