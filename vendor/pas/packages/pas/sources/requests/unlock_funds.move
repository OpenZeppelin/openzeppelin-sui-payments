module pas::unlock_funds;

use pas::{
    keys::unlock_funds_action,
    namespace::Namespace,
    policy::Policy,
    request::{Self, Request}
};
use sui::{balance::Balance, vec_set};

#[error(code = 0)]
const ECannotResolveManagedAssets: vector<u8> =
    b"Cannot resolve managed assets without the issuer's permission.";

/// An unlock funds request that is generated once a Permissioned Funds Transfer is initiated.
///
/// This can be resolved in two ways:
/// 1. If the asset is `permissioned` (there's a `Policy<T>` for that asset), it can only be resolved by the creator
/// by calling `policy::resolve_unlock_funds`
/// 2. If the asset is not permissioned, it can be resolved by any address by calling `unlock_funds::resolve_unrestricted_balance`
public struct UnlockFunds<T: store> {
    /// `owner` is the wallet OR object address, NOT the account address
    owner: address,
    /// The ID of the account the funds are coming from
    account_id: ID,
    /// The actual balance being transferred
    funds: T,
}

public fun owner<T: store>(request: &UnlockFunds<T>): address { request.owner }

public fun account_id<T: store>(request: &UnlockFunds<T>): ID { request.account_id }

public fun funds<T: store>(request: &UnlockFunds<T>): &T { &request.funds }

/// This enables unlocking assets that are not managed by a Policy within the system.
/// If a `Policy<T>` exists, they can only be resolved from within the system.
///
/// For example, `SUI` will never be a managed asset, so the owner needs to be able
/// to withdraw if anyone transfers some to their account.
public fun resolve_unrestricted_balance<C>(
    request: Request<UnlockFunds<Balance<C>>>,
    namespace: &Namespace,
): Balance<C> {
    assert!(!namespace.policy_exists<Balance<C>>(), ECannotResolveManagedAssets);
    namespace.versioning().assert_is_valid_version();
    let data = request.resolve(vec_set::empty());
    let UnlockFunds { funds, .. } = data;
    funds
}

/// Resolve an unlock funds request as long as funds management is enabled and
/// there are enough valid approvals.
public fun resolve<T: store>(request: Request<UnlockFunds<T>>, policy: &Policy<T>): T {
    policy.versioning().assert_is_valid_version();
    let data = request.resolve(policy.required_approvals(unlock_funds_action()));

    let UnlockFunds { funds, .. } = data;
    funds
}

public(package) fun new<T: store>(
    owner: address,
    account_id: ID,
    funds: T,
): Request<UnlockFunds<T>> {
    request::new(UnlockFunds { owner, account_id, funds })
}
