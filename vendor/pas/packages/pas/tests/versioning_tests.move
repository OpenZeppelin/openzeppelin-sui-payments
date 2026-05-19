#[test_only, allow(unused_variable, unused_mut_ref, dead_code)]
module pas::versioning_tests;

use pas::{
    account,
    e2e::{package_id, test_tx, A},
    namespace::{Self, Namespace},
    versioning::breaking_version
};
use ptb::ptb::Command;
use std::unit_test::assert_eq;
use sui::{package::UpgradeCap, test_scenario::Scenario};

#[test, expected_failure(abort_code = ::pas::namespace::EUpgradeCapAlreadySet)]
fun tries_to_setup_namespace_twice() {
    let mut scenario = sui::test_scenario::begin(@0x0);
    namespace::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x0);

    let mut namespace = scenario.take_shared<Namespace>();

    let package_id = package_id<Namespace>();

    let upgrade_cap = sui::package::test_publish(package_id, scenario.ctx());
    namespace.setup(&upgrade_cap);
    namespace.setup(&upgrade_cap);

    abort
}

#[test, expected_failure(abort_code = ::pas::namespace::EUpgradeCapPackageMismatch)]
fun tries_to_setup_namespace_with_invalid_upgrade_cap() {
    let mut scenario = sui::test_scenario::begin(@0x0);
    namespace::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x0);

    let mut namespace = scenario.take_shared<Namespace>();

    // create the upgrade cap from a type coming from a dependency.
    let package_id = package_id<Command>();

    let upgrade_cap = sui::package::test_publish(package_id, scenario.ctx());
    namespace.setup(&upgrade_cap);

    abort
}

#[test, expected_failure(abort_code = ::pas::namespace::EUpgradeCapPackageMismatch)]
fun tries_to_block_version_with_invalid_upgrade_cap() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);

        let upgrade_cap = sui::package::test_publish(package_id<Command>(), scenario.ctx());
        namespace.block_version(&upgrade_cap, 1);

        abort
    });
}

#[test, expected_failure(abort_code = ::pas::namespace::EUpgradeCapPackageMismatch)]
fun tries_to_unblock_version_with_invalid_upgrade_cap() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);

        let upgrade_cap = sui::package::test_publish(package_id<Command>(), scenario.ctx());
        namespace.unblock_version(&upgrade_cap, 1);

        abort
    });
}

#[test]
fun block_unblock_versions_and_sync_with_accounts_and_policies() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let upgrade_cap = scenario.take_from_sender<UpgradeCap>();

        let mut account = account::create(namespace, @0x1);

        namespace.block_version(&upgrade_cap, 1);
        assert!(!namespace.versioning().is_valid_version(1));
        account.sync_versioning(namespace);
        managed_policy.sync_versioning(namespace);
        assert_eq!(account.versioning(), namespace.versioning());
        assert!(!account.versioning().is_valid_version(1));
        assert!(!managed_policy.versioning().is_valid_version(1));

        namespace.unblock_version(&upgrade_cap, 1);
        account.sync_versioning(namespace);
        managed_policy.sync_versioning(namespace);
        assert!(namespace.versioning().is_valid_version(1));
        assert!(account.versioning().is_valid_version(1));
        assert!(managed_policy.versioning().is_valid_version(1));

        account.share();
        scenario.return_to_sender(upgrade_cap);
    });
}

#[test, expected_failure(abort_code = ::pas::versioning::EInvalidVersion)]
fun try_to_create_account_with_invalid_version() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        namespace.block_current_version(scenario);

        let _account = account::create(namespace, @0x1);
        abort
    });
}

#[test, expected_failure(abort_code = ::pas::versioning::EInvalidVersion)]
fun try_unlock_funds_invalid_version_on_account() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        let mut account = account::create(namespace, @0x1);

        namespace.block_current_version(scenario);
        account.sync_versioning(namespace);
        let auth = account::new_auth(scenario.ctx());
        let req = account.unlock_balance<A>(&auth, 50, scenario.ctx());
        abort
    });
}

use fun block_current_version as Namespace.block_current_version;

fun block_current_version(namespace: &mut Namespace, scenario: &Scenario) {
    let upgrade_cap = scenario.take_from_sender<UpgradeCap>();
    namespace.block_version(&upgrade_cap, breaking_version!());
    scenario.return_to_sender(upgrade_cap);
}
