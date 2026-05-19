#[test_only, allow(unused_variable, unused_mut_ref, dead_code)]
module pas::policy_setup_tests;

use pas::{account, e2e::{test_tx, A}, policy::PolicyCap, send_funds};
use sui::balance::{Self, Balance};

public struct InvalidActionApproval() has drop;

public struct NewActionApproval() has drop;

#[test]
fun override_action_approval() {
    test_tx!(@0x1, |namespace, managed_policy, unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);

        let policy_cap = scenario.take_from_sender<PolicyCap<sui::balance::Balance<A>>>();
        managed_policy.set_required_approval<_, NewActionApproval>(&policy_cap, "send_funds");

        // Do a test transfer to verify the override auth works
        {
            let mut account = account::create(namespace, @0x1);

            account.deposit_balance(balance::create_for_testing<A>(100));

            let auth = account::new_auth(scenario.ctx());
            let mut transfer_request = account.unsafe_send_balance<A>(
                &auth,
                @0x2,
                50,
                scenario.ctx(),
            );
            transfer_request.approve(NewActionApproval());
            send_funds::resolve_balance(transfer_request, managed_policy);

            account.share();
        };

        scenario.return_to_sender(policy_cap);
    });
}

#[test, expected_failure(abort_code = ::pas::policy::EInvalidAction)]
fun set_invalid_action_approval() {
    test_tx!(@0x1, |namespace, managed_policy, unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);

        let policy_cap = scenario.take_from_sender<PolicyCap<Balance<A>>>();
        managed_policy.set_required_approval<_, InvalidActionApproval>(
            &policy_cap,
            "invalid_action",
        );

        abort
    });
}
