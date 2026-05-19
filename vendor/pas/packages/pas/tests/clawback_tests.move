#[test_only, allow(unused_variable, unused_mut_ref, dead_code)]
module pas::clawback_tests;

use pas::{
    account,
    clawback_funds,
    e2e::{test_tx, a_witness, A, b_witness, B, AWitness},
    policy::PolicyCap
};
use std::{type_name, unit_test::assert_eq};
use sui::balance::{Self, Balance};

#[test]
fun clawback_managed_assets() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        account.deposit_balance(balance::create_for_testing<A>(100));

        let mut clawback_request = account.clawback_balance<A>(50, scenario.ctx());
        assert_eq!(clawback_request.data().funds().value(), 50);
        assert_eq!(clawback_request.data().owner(), @0x1);
        assert_eq!(clawback_request.data().account_id(), namespace.account_address(@0x1).to_id());

        clawback_request.approve(a_witness());

        assert_eq!(clawback_request.approvals().length(), 1);
        assert!(clawback_request.approvals().contains(&type_name::with_defining_ids<AWitness>()));

        let balance = clawback_funds::resolve(clawback_request, managed_policy);

        assert_eq!(balance.value(), 50);

        account.share();

        balance.send_funds(@0x10);
    });
}

#[test, expected_failure(abort_code = ::pas::policy::ENotSupportedAction)]
fun try_to_clawback_when_clawback_stamp_is_not_set() {
    test_tx!(@0x1, |namespace, managed_policy, _r, scenario| {
        scenario.next_tx(@0x1);

        let policy_cap = scenario.take_from_sender<PolicyCap<Balance<A>>>();
        managed_policy.remove_action_approval(&policy_cap, "clawback_funds");

        let mut account = account::create(namespace, @0x1);
        account.deposit_balance(balance::create_for_testing<A>(100));

        let mut clawback_request = account.clawback_balance<A>(50, scenario.ctx());
        clawback_request.approve(a_witness());

        let balance = clawback_funds::resolve(clawback_request, managed_policy);
        abort
    });
}

#[test, expected_failure(abort_code = ::pas::clawback_funds::EClawbackNotAllowed)]
fun try_to_clawback_unmanaged_assets() {
    test_tx!(@0x1, |namespace, _managed_policy, unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);
        account.deposit_balance(balance::create_for_testing<B>(100));

        let mut clawback_request = account.clawback_balance<B>(50, scenario.ctx());
        clawback_request.approve(b_witness());

        let _balance = clawback_funds::resolve(clawback_request, unmanaged_policy);

        abort
    });
}
