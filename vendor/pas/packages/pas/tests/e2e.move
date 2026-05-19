#[test_only, allow(unused_variable, unused_mut_ref, dead_code)]
module pas::e2e;

use pas::{account::{Self, Account}, policy::{Self, PolicyCap}, send_funds, unlock_funds};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{balance::{Self, send_funds, Balance}, sui::SUI, test_scenario::return_shared, vec_set};

public struct A has drop {}
public struct B has drop {}
public struct ExtUSD has drop {}

public struct AWitness() has drop;
public struct BWitness() has drop;

#[test]
fun e2e() {
    test_tx!(@0x1, |namespace, managed_policy, unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);

        let namespace_id = object::id(namespace);

        // create accounts of 0x1 and 0x2
        let account = account::create(namespace, @0x1);
        let another_account = account::create(namespace, @0x2);

        // transfer some funds to both 0x1 and 0x2
        account.deposit_balance(balance::create_for_testing<A>(100));

        balance::create_for_testing<B>(50).send_funds(namespace.account_address(@0x2));

        account.share();
        another_account.share();

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(
                @0x1,
            )
            .to_id());
        let another_account = scenario.take_shared_by_id<Account>(namespace
            .account_address(@0x2)
            .to_id());

        let auth = account::new_auth(scenario.ctx());
        let mut transfer_request = account.send_balance<A>(
            &auth,
            &another_account,
            50,
            scenario.ctx(),
        );

        transfer_request.approve(AWitness());
        send_funds::resolve_balance(transfer_request, managed_policy);

        return_shared(account);
        return_shared(another_account);
    });
}

#[test, expected_failure(abort_code = ::pas::request::EInsufficientApprovals)]
fun try_to_approve_transfer_with_invalid_witness() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        let namespace_id = object::id(namespace);
        scenario.next_tx(@0x1);
        account::create_and_share(namespace, @0x1);

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(
                @0x1,
            )
            .to_id());

        let auth = account::new_auth(scenario.ctx());
        let mut transfer_request = account.unsafe_send_balance<A>(
            &auth,
            @0x2,
            50,
            scenario.ctx(),
        );

        // Add an invalid approval to the request
        transfer_request.approve(BWitness());
        send_funds::resolve_balance(transfer_request, managed_policy);

        abort
    });
}

#[test]
fun test_address_and_derivation_matches() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        let user_one_account_id = namespace.account_address(@0x1).to_id();
        let user_two_account_id = namespace.account_address(@0x2).to_id();

        scenario.next_tx(@0x1);
        account::create_and_share(namespace, @0x1);
        account::create_and_share(namespace, @0x2);

        scenario.next_tx(@0x1);

        let mut user_one_account = scenario.take_shared_by_id<Account>(user_one_account_id);
        let user_two_account = scenario.take_shared_by_id<Account>(user_two_account_id);

        let auth = account::new_auth(scenario.ctx());

        let transfer_request = user_one_account.unsafe_send_balance<A>(
            &auth,
            @0x2,
            50,
            scenario.ctx(),
        );

        assert_eq!(transfer_request.data().sender(), @0x1);
        assert_eq!(transfer_request.data().recipient(), @0x2);
        assert_eq!(transfer_request.data().sender_account_id(), user_one_account_id);
        assert_eq!(transfer_request.data().recipient_account_id(), user_two_account_id);
        assert_eq!(transfer_request.data().funds().value(), 50);

        // Both scenarios must calculate the from/to equivalent.
        let safe_request = user_one_account.send_balance<A>(
            &auth,
            &user_two_account,
            50,
            scenario.ctx(),
        );
        assert_eq!(safe_request.data().sender(), @0x1);
        assert_eq!(safe_request.data().recipient(), @0x2);
        assert_eq!(safe_request.data().sender_account_id(), user_one_account_id);
        assert_eq!(safe_request.data().recipient_account_id(), user_two_account_id);
        assert_eq!(safe_request.data().funds().value(), 50);

        destroy(transfer_request);
        destroy(safe_request);

        return_shared(user_one_account);
        return_shared(user_two_account);
    });
}

#[test]
fun unlock_funds_successfully() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        account.deposit_balance(balance::create_for_testing<A>(100));

        let auth = account::new_auth(scenario.ctx());
        let mut unlock_request = account.unlock_balance<A>(&auth, 50, scenario.ctx());

        unlock_request.approve(AWitness());
        let balance = unlock_funds::resolve(unlock_request, managed_policy);

        assert_eq!(balance.value(), 50);

        account.share();
        balance.send_funds(@0x10);
    });
}

#[test, expected_failure(abort_code = ::pas::unlock_funds::ECannotResolveManagedAssets)]
fun try_to_resolve_unlock_funds_request_for_managed_assets() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        account.deposit_balance(balance::create_for_testing<A>(100));

        let auth = account::new_auth(scenario.ctx());
        let unlock_request = account.unlock_balance<A>(&auth, 50, scenario.ctx());

        let _balance = unlock_funds::resolve_unrestricted_balance(unlock_request, namespace);

        abort
    });
}

#[test]
fun unlock_non_managed_funds() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        account.deposit_balance(balance::create_for_testing<SUI>(100));

        let auth = account::new_auth(scenario.ctx());
        let unlock_request = account.unlock_balance<SUI>(&auth, 100, scenario.ctx());
        let balance = unlock_funds::resolve_unrestricted_balance(unlock_request, namespace);

        balance.send_funds(@0x1);

        account.share();
    });
}

#[test]
fun derivation_is_consistent() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let account = account::create(namespace, @0x1);

        assert_eq!(namespace.account_address(@0x1), object::id(&account).to_address());
        assert_eq!(namespace.policy_address<Balance<A>>(), object::id(managed_policy).to_address());

        account.share();
    });
}

#[test]
fun test_unlock_request_getters() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        account.deposit_balance(balance::create_for_testing<A>(100));

        let auth = account::new_auth(scenario.ctx());

        let unlock_request = account.unlock_balance<A>(&auth, 50, scenario.ctx());

        assert_eq!(unlock_request.data().owner(), @0x1);
        assert_eq!(unlock_request.data().account_id(), namespace.account_address(@0x1).to_id());
        assert_eq!(unlock_request.data().funds().value(), 50);

        destroy(unlock_request);
        account.share();
    });
}

#[test, expected_failure(abort_code = ::pas::policy::EPolicyAlreadyExists)]
fun try_to_create_duplicate_policy() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let mut treasury_cap = sui::coin::create_treasury_cap_for_testing<A>(scenario.ctx());
        let (policy, policy_cap) = policy::new_for_currency(namespace, &mut treasury_cap, true);

        abort
    });
}

#[test]
fun multiple_approvals_required() {
    test_tx!(@0x1, |namespace, managed_policy, unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);

        let namespace_id = object::id(namespace);
        let policy_cap = scenario.take_from_sender<PolicyCap<Balance<A>>>();

        let mut approvals = vec_set::empty();
        approvals.insert(type_name::with_defining_ids<AWitness>());
        approvals.insert(type_name::with_defining_ids<BWitness>());

        managed_policy.set_required_approvals(&policy_cap, "send_funds", approvals);

        scenario.return_to_sender(policy_cap);

        // create accounts of 0x1 and 0x2
        let account = account::create(namespace, @0x1);

        // transfer some funds to both 0x1 and 0x2
        account.deposit_balance(balance::create_for_testing<A>(100));
        account.share();

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(
                @0x1,
            )
            .to_id());

        let auth = account::new_auth(scenario.ctx());
        let mut transfer_request = account.unsafe_send_balance<A>(
            &auth,
            @0x2,
            50,
            scenario.ctx(),
        );

        transfer_request.approve(AWitness());
        transfer_request.approve(BWitness());
        send_funds::resolve_balance(transfer_request, managed_policy);

        return_shared(account);
    });
}

#[test, expected_failure(abort_code = ::pas::request::EInsufficientApprovals)]
fun multiple_approvals_invalid_order_failure() {
    test_tx!(@0x1, |namespace, managed_policy, unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);

        let namespace_id = object::id(namespace);
        let policy_cap = scenario.take_from_sender<PolicyCap<Balance<A>>>();

        let mut approvals = vec_set::empty();
        approvals.insert(type_name::with_defining_ids<AWitness>());
        approvals.insert(type_name::with_defining_ids<BWitness>());

        managed_policy.set_required_approvals(&policy_cap, "send_funds", approvals);

        scenario.return_to_sender(policy_cap);

        // create accounts of 0x1 and 0x2
        let account = account::create(namespace, @0x1);

        // transfer some funds to both 0x1 and 0x2
        account.deposit_balance(balance::create_for_testing<A>(100));
        account.share();

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(
                @0x1,
            )
            .to_id());

        let auth = account::new_auth(scenario.ctx());
        let mut transfer_request = account.unsafe_send_balance<A>(
            &auth,
            @0x2,
            50,
            scenario.ctx(),
        );
        transfer_request.approve(BWitness());
        transfer_request.approve(AWitness());

        send_funds::resolve_balance(transfer_request, managed_policy);
        abort
    });
}

#[test, expected_failure(abort_code = ::pas::request::EInvalidNumberOfApprovals)]
fun cannot_have_extra_approvals() {
    test_tx!(@0x1, |namespace, managed_policy, unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);

        let namespace_id = object::id(namespace);

        // create accounts of 0x1 and 0x2
        let account = account::create(namespace, @0x1);

        // transfer some funds to both 0x1 and 0x2
        account.deposit_balance(balance::create_for_testing<A>(100));
        account.share();

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(
                @0x1,
            )
            .to_id());

        let auth = account::new_auth(scenario.ctx());
        let mut transfer_request = account.unsafe_send_balance<A>(
            &auth,
            @0x2,
            50,
            scenario.ctx(),
        );
        transfer_request.approve(BWitness());
        transfer_request.approve(AWitness());

        send_funds::resolve_balance(transfer_request, managed_policy);
        abort
    });
}

public fun package_id<T>(): ID {
    sui::address::from_ascii_bytes(std::type_name::with_defining_ids<T>()
        .address_string()
        .as_bytes()).to_id()
}

public fun a_permit(): internal::Permit<A> {
    internal::permit()
}

public fun b_permit(): internal::Permit<B> {
    internal::permit()
}

public fun a_witness(): AWitness {
    AWitness()
}

public fun b_witness(): BWitness {
    BWitness()
}

/// A test_tx already set up for convenience.
public macro fun test_tx(
    $admin: address,
    $f: |
        &mut pas::namespace::Namespace,
        &mut pas::policy::Policy<sui::balance::Balance<A>>,
        &mut pas::policy::Policy<sui::balance::Balance<B>>,
        &mut sui::test_scenario::Scenario,
    |,
) {
    let mut scenario = sui::test_scenario::begin($admin);

    pas::namespace::init_for_testing(scenario.ctx());

    scenario.next_tx($admin);

    let mut namespace = scenario.take_shared<pas::namespace::Namespace>();

    let package_id = pas::e2e::package_id<pas::namespace::Namespace>();

    let upgrade_cap = sui::package::test_publish(package_id, scenario.ctx());
    namespace.setup(&upgrade_cap);
    sui::transfer::public_transfer(upgrade_cap, $admin);

    pas::templates::setup(&mut namespace);

    let mut treasury_cap_a = sui::coin::create_treasury_cap_for_testing<A>(scenario.ctx());
    let (mut policy_a, policy_cap_a) = pas::policy::new_for_currency(
        &mut namespace,
        &mut treasury_cap_a,
        true,
    );

    policy_a.set_required_approval<_, AWitness>(&policy_cap_a, "send_funds");
    policy_a.set_required_approval<_, AWitness>(&policy_cap_a, "unlock_funds");
    policy_a.set_required_approval<_, AWitness>(&policy_cap_a, "clawback_funds");
    sui::transfer::public_transfer(policy_cap_a, $admin);
    std::unit_test::destroy(treasury_cap_a);
    policy_a.share();

    let mut treasury_cap_b = sui::coin::create_treasury_cap_for_testing<B>(scenario.ctx());
    let (mut policy_b, policy_cap_b) = pas::policy::new_for_currency(
        &mut namespace,
        &mut treasury_cap_b,
        false,
    );

    policy_b.set_required_approval<_, BWitness>(&policy_cap_b, "send_funds");
    policy_b.set_required_approval<_, BWitness>(&policy_cap_b, "unlock_funds");

    std::unit_test::destroy(treasury_cap_b);
    std::unit_test::destroy(policy_cap_b);
    policy_b.share();

    scenario.next_tx($admin);

    let mut managed_policy = scenario.take_shared<pas::policy::Policy<sui::balance::Balance<A>>>();
    let mut unmanaged_policy = scenario.take_shared<
        pas::policy::Policy<sui::balance::Balance<B>>,
    >();

    $f(
        &mut namespace,
        &mut managed_policy,
        &mut unmanaged_policy,
        &mut scenario,
    );

    scenario.next_tx($admin);

    sui::test_scenario::return_shared(namespace);
    sui::test_scenario::return_shared(managed_policy);
    sui::test_scenario::return_shared(unmanaged_policy);
    scenario.end();
}
