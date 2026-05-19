/// Versioning module.
///
/// This module is responsible for managing the versioning of the package.
///
/// It allows for blocking specific versions of the package in case of emergency, or to slowly deprecate an earlier feature.
module pas::versioning;

use sui::vec_set::{Self, VecSet};

#[error(code = 0)]
const EInvalidVersion: vector<u8> =
    b"This version of the core package (pas) is no longer supported. Please use the latest version of the package.";

public struct Versioning has copy, drop, store {
    blocked_versions: VecSet<u64>,
}

public(package) fun new(): Versioning {
    Versioning {
        blocked_versions: vec_set::empty(),
    }
}

public(package) fun block_version(versioning: &mut Versioning, version: u64) {
    versioning.blocked_versions.insert(version);
}

public(package) fun unblock_version(versioning: &mut Versioning, version: u64) {
    versioning.blocked_versions.remove(&version);
}

/// Verify that a version is not part of the blocked version list.
public fun is_valid_version(versioning: &Versioning, version: u64): bool {
    !versioning.blocked_versions.contains(&version)
}

public fun assert_is_valid_version(versioning: &Versioning) {
    assert!(versioning.is_valid_version(breaking_version!()), EInvalidVersion);
}

/// The current package's breaking version.
///
/// A breaking version is not equal to the released version. It acts as a marker to allow
/// disabling specific packages.
///
/// This is bumped only in case of emergency, or to slowly deprecate an earlier feature.
public macro fun breaking_version(): u64 { 1 }
