module pas::request;

use std::type_name::{Self, TypeName};
use sui::vec_set::{Self, VecSet};

#[error(code = 0)]
const EInsufficientApprovals: vector<u8> =
    b"Cannot resolve request: insufficient or invalid approvals received.";

#[error(code = 1)]
const EInvalidNumberOfApprovals: vector<u8> =
    b"Cannot resolve request: Invalid number of approvals received.";

/// A base request type.
/// Examples:
/// `Request<SendFunds<T>>`
/// `Request<UnlockFunds<T>>`
public struct Request<K> {
    /// The collected approvals for this request
    approvals: VecSet<TypeName>,
    data: K,
}

/// Adds an approval to a request. Can be called to resolve rules
public fun approve<K, U: drop>(request: &mut Request<K>, _approval: U) {
    request.approvals.insert(type_name::with_defining_ids<U>());
}

public fun data<K>(request: &Request<K>): &K {
    &request.data
}

public fun approvals<K>(request: &Request<K>): VecSet<TypeName> {
    request.approvals
}

public(package) fun new<K>(data: K): Request<K> {
    Request {
        approvals: vec_set::empty(),
        data,
    }
}

/// An internal function to resolve a request.
public(package) fun resolve<K>(request: Request<K>, required_approvals: VecSet<TypeName>): K {
    assert!(request.approvals.length() == required_approvals.length(), EInvalidNumberOfApprovals);
    request.approvals.into_keys().zip_do_ref!(&required_approvals.into_keys(), |a, b| {
        assert!(a == b, EInsufficientApprovals);
    });
    let Request { data, .. } = request;
    data
}
