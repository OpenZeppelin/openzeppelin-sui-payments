/// Merchant identity and central configuration.
///
/// Defines:
/// - `MerchantConfig` — shared object. Holds:
///     - display metadata (name, optional logo_url)
///     - payment routing (payout_address — where customer payments land via PAS)
///     - loyalty asset linkage: `loyalty_treasury_cap: TreasuryCap<LOYALTY>` (mints + burns),
///       `loyalty_policy_id: ID`, `loyalty_namespace_id: ID`
///     - mint policy: `mint_numerator: u64`, `mint_denominator: u64`,
///       `max_mint_per_payment: u64`
///     - catalog: `listings: Table<u64, Listing>`, `next_listing_id: u64`
/// - `MerchantCap` — owned capability, passed by reference to gate:
///     `listing::add/update/remove/set_active`, `redemption::verify`, payout-side helpers.
///
/// Module init (one-shot per template deployment) creates the loyalty asset, the
/// PAS namespace + policy, the `MerchantConfig` shared object, and the `MerchantCap`;
/// transfers `MerchantCap` to the publisher.
module openzeppelin_payments::merchant;
