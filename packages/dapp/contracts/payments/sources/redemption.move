/// Redemption flow — extracts loyalty balance from the customer's PAS Account into a
/// `Hold` shared object, burns on merchant verify, returns to customer on expiry.
///
/// `request_redeem` flow:
///   1. `unlock_balance` from customer's loyalty Account → `Request<UnlockFunds<Balance<LOYALTY>>>`
///   2. Attach `RedeemUnlockApproval` (from `loyalty`) → resolve via `Policy<LOYALTY>`
///   3. Stash the resulting `Balance<LOYALTY>` inside a freshly-shared `Hold`
///
/// `verify(&MerchantCap, hold, code, clock)`:
///   - Asserts `hash(code) == hold.code_hash` and not expired.
///   - Destroys `Hold`, burns `Balance<LOYALTY>` via `MerchantConfig.loyalty_treasury_cap`.
///
/// `release(hold, customer_account, clock)` — **permissionless** after expiry:
///   - Asserts expired and that the supplied Account belongs to `hold.customer`.
///   - Destroys `Hold`, deposits the held `Balance<LOYALTY>` back into the customer's Account.
///   - Prevents griefing by an inactive merchant.
module openzeppelin_payments::redemption;
