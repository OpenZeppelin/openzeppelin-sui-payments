/// The Namespace module.
///
/// Namespace is responsible for creating objects that are easy to query & find:
/// 1. Accounts
/// 2. Policies
/// ... any other module we might add in the future
module pas::namespace;

use pas::{keys, versioning::{Self, Versioning}};
use std::type_name;
use sui::{derived_object, package::UpgradeCap};

#[error(code = 0)]
const EUpgradeCapAlreadySet: vector<u8> = b"The upgrade cap is already set for this namespace.";
#[error(code = 1)]
const EUpgradeCapPackageMismatch: vector<u8> =
    b"The upgrade cap package does not match the package.";
#[error(code = 2)]
const EUpgradeCapNotSet: vector<u8> =
    b"The upgrade cap is not set for this namespace, making it unusable.";

/// The namespace is only used for address derivation of accounts, policies, etc.
///
/// Namespace is a singleton -- there's one global version for it.
public struct Namespace has key {
    id: UID,
    /// The UpgradeCap of the package, used as the "ownership" capability, mainly to
    /// block versions of the package in case of emergency.
    upgrade_cap_id: Option<ID>,
    /// Enables "blocking" versions of the package
    versioning: Versioning,
}

// We publish the Namespace in the `init` function, since it's "singleton".
fun init(ctx: &mut TxContext) {
    transfer::share_object(Namespace {
        id: object::new(ctx),
        upgrade_cap_id: option::none(),
        versioning: versioning::new(),
    });
}

/// Setup the namespace (links the `UpgradeCap`) once after publishing. This makes the UpgradeCap the "admin" capability
/// (which can set the blocked versions of a package).
entry fun setup(namespace: &mut Namespace, cap: &UpgradeCap) {
    // setup is already done for upgrade cap
    assert!(namespace.upgrade_cap_id.is_none(), EUpgradeCapAlreadySet);

    // Verify the `UpgradeCap` is correct for this package.
    assert!(
        type_name::with_defining_ids<Namespace>().address_string() == cap.package().to_address().to_ascii_string(),
        EUpgradeCapPackageMismatch,
    );

    namespace.upgrade_cap_id = option::some(object::id(cap));
}

/// Allows the package admin to block a version of the package.
///
/// This is only used in case of emergency (e.g. security consideration), or if there is a breaking change
public fun block_version(namespace: &mut Namespace, cap: &UpgradeCap, version: u64) {
    assert!(namespace.is_valid_upgrade_cap(cap), EUpgradeCapPackageMismatch);
    namespace.versioning.block_version(version);
}

/// Allows the package admin to unblock a version of the package.
public fun unblock_version(namespace: &mut Namespace, cap: &UpgradeCap, version: u64) {
    assert!(namespace.is_valid_upgrade_cap(cap), EUpgradeCapPackageMismatch);
    namespace.versioning.unblock_version(version);
}

/// Check if `Policy<T>` exists in the namespace
public fun policy_exists<T>(namespace: &Namespace): bool {
    derived_object::exists(&namespace.id, keys::policy_key<T>())
}

/// The derived address for `Policy<T>`
public fun policy_address<T>(namespace: &Namespace): address {
    derived_object::derive_address(namespace.id.to_inner(), keys::policy_key<T>())
}

public fun account_exists(namespace: &Namespace, owner: address): bool {
    derived_object::exists(&namespace.id, keys::account_key(owner))
}

public fun account_address(namespace: &Namespace, owner: address): address {
    derived_object::derive_address(namespace.id.to_inner(), keys::account_key(owner))
}

// Given the name space ID, calculate the account address.
public(package) fun account_address_from_id(namespace_id: ID, owner: address): address {
    derived_object::derive_address(namespace_id, keys::account_key(owner))
}

public(package) fun versioning(namespace: &Namespace): Versioning {
    namespace.versioning
}

/// Expose `uid_mut` so we can claim derived objects from other modules.
public(package) fun uid_mut(namespace: &mut Namespace): &mut UID {
    // We can only do it after we have set the upgrade cap (to prevent usage of the system before it has been set up).
    assert!(namespace.upgrade_cap_id.is_some(), EUpgradeCapNotSet);
    &mut namespace.id
}

fun is_valid_upgrade_cap(namespace: &Namespace, cap: &UpgradeCap): bool {
    namespace.upgrade_cap_id.is_some_and!(|id| id == object::id(cap))
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun create_for_testing(ctx: &mut TxContext): Namespace {
    Namespace {
        id: object::new(ctx),
        upgrade_cap_id: option::none(),
        versioning: versioning::new(),
    }
}

#[test_only]
public fun share_for_testing(namespace: Namespace) {
    transfer::share_object(namespace);
}
