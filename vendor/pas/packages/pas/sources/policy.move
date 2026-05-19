module pas::policy;

use pas::{keys, namespace::Namespace, versioning::Versioning};
use std::{string::String, type_name::{Self, TypeName}};
use sui::{
    balance::Balance,
    coin::TreasuryCap,
    derived_object,
    vec_map::{Self, VecMap},
    vec_set::{Self, VecSet}
};

#[error(code = 0)]
const EPolicyAlreadyExists: vector<u8> = b"A policy for this token type already exists.";
#[error(code = 1)]
const EInvalidAction: vector<u8> = b"Invalid action type.";
#[error(code = 2)]
const ENotSupportedAction: vector<u8> =
    b"The requested action type is not supported by the issuer.";

/// A policy is set by the owner of `T`, and points to a `TypeName` that needs
/// to be verified by the entity's contract.
///
/// This is derived from `namespace, TypeName<T>`
public struct Policy<phantom T> has key {
    id: UID,
    /// The required approvals per request type.
    /// The key must be one of the request types (e.g. `send_funds`, `unlock_funds` or `clawback_funds`).
    ///
    /// The value is a vector of approvals that need to be gather to resolve the request.
    required_approvals: VecMap<String, VecSet<TypeName>>,
    /// Block versions to break backwards compatibility -- only used in case of emergency.
    versioning: Versioning,
    /// Whether clawback is allowed for this policy.
    clawback_allowed: bool,
}

/// Capability for managing a `Policy<T>`. It's 1:1.
public struct PolicyCap<phantom T> has key, store {
    id: UID,
}

/// Key that is used to derive the PolicyCap ID from `Policy<T>`
public struct PolicyCapKey() has copy, drop, store;

public fun new_for_currency<C>(
    namespace: &mut Namespace,
    _cap: &mut TreasuryCap<C>,
    clawback_allowed: bool,
): (Policy<Balance<C>>, PolicyCap<Balance<C>>) {
    assert!(!namespace.policy_exists<Balance<C>>(), EPolicyAlreadyExists);

    let versioning = namespace.versioning();
    versioning.assert_is_valid_version();

    let mut policy = Policy<Balance<C>> {
        id: derived_object::claim(namespace.uid_mut(), keys::policy_key<Balance<C>>()),
        required_approvals: vec_map::empty(),
        versioning,
        clawback_allowed,
    };

    let policy_cap = PolicyCap<Balance<C>> {
        id: derived_object::claim(&mut policy.id, PolicyCapKey()),
    };

    (policy, policy_cap)
}

public fun share<T>(policy: Policy<T>) {
    transfer::share_object(policy);
}

/// Get the set of required approvals for a given action.
public fun required_approvals<T>(policy: &Policy<T>, action_type: String): VecSet<TypeName> {
    assert!(policy.required_approvals.contains(&action_type), ENotSupportedAction);
    *policy.required_approvals.get(&action_type)
}

public fun set_required_approval<T, A: drop>(
    policy: &mut Policy<T>,
    cap: &PolicyCap<T>,
    action: String,
) {
    policy.set_required_approvals(
        cap,
        action,
        vec_set::singleton(type_name::with_defining_ids<A>()),
    );
}

/// Remove the action approval for a given action (this will make all requests not resolve).
public fun remove_action_approval<T>(policy: &mut Policy<T>, _: &PolicyCap<T>, action: String) {
    policy.versioning.assert_is_valid_version();
    policy.required_approvals.remove(&action);
}

/// Allows syncing the versioning of a policy to the namespace's versioning.
/// This is permission-less and can be done by anyone.
public fun sync_versioning<T>(policy: &mut Policy<T>, namespace: &Namespace) {
    policy.versioning = namespace.versioning();
}

/// For a set of actions, set the approvals required to conclude the action.
///
/// Supported actions: ["send_funds", "unlock_funds", "clawback_funds"]
public(package) fun set_required_approvals<T>(
    policy: &mut Policy<T>,
    _: &PolicyCap<T>,
    action: String,
    approvals: VecSet<TypeName>,
) {
    policy.versioning.assert_is_valid_version();
    assert!(keys::is_valid_action(action), EInvalidAction);

    if (policy.required_approvals.contains(&action)) {
        policy.required_approvals.remove(&action);
    };
    policy.required_approvals.insert(action, approvals);
}

/// Check if clawback is allowed or not.
/// Aborts early if the management for funds has not been enabled for `T`.
public(package) fun is_clawback_allowed<T>(policy: &Policy<T>): bool {
    policy.versioning.assert_is_valid_version();
    policy.clawback_allowed
}

public(package) fun versioning<T>(policy: &Policy<T>): Versioning { policy.versioning }
