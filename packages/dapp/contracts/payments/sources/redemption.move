/// Redemption flow — places a hold on soulbound loyalty balance, burns on merchant
/// verification, releases on expiry.
///
/// - `request_redeem(...)` — customer locks `amount` of soulbound balance into a `Hold`
///   object that stores `hash(code)` (commit-reveal) and a `Clock`-based expiry.
/// - `verify(..., code, &MerchantCap)` — merchant submits the code preimage; the held
///   balance is burned and a $0 verification event is emitted.
/// - `release(...)` — **permissionless** after `expiry`; returns held balance to customer
///   so an inactive merchant cannot grief.
module openzeppelin_payments::redemption;
