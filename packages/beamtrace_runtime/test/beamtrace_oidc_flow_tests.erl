%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_oidc_flow_tests).

-include_lib("eunit/include/eunit.hrl").

callback_state_has_exactly_one_concurrent_consumer_test_() ->
    {timeout, 10, fun callback_state_has_exactly_one_concurrent_consumer/0}.

callback_state_has_exactly_one_concurrent_consumer() ->
    Store = beamtrace_oidc_flow_ffi:new(),
    State = <<"one-time-state">>,
    Attempt = {
        attempt,
        State,
        <<"nonce">>,
        <<"challenge">>,
        <<"https://hub.example/callback">>,
        2000,
        false
    },
    ?assertEqual(
        {ok, nil},
        beamtrace_oidc_flow_ffi:remember(Store, State, Attempt, <<"verifier">>, 2000)
    ),
    Parent = self(),
    [spawn(fun() ->
        Parent ! {result, beamtrace_oidc_flow_ffi:consume(Store, State, 1000)}
    end) || _ <- lists:seq(1, 20)],
    Results = [receive {result, Result} -> Result after 5000 -> error(timeout) end
        || _ <- lists:seq(1, 20)],
    Successes = [Result || Result = {ok, _} <- Results],
    ?assertEqual(1, length(Successes)),
    ?assert(lists:all(fun
        ({ok, _}) -> true;
        ({error, <<"already_used">>}) -> true;
        ({error, <<"invalid_state">>}) -> true;
        (_) -> false
    end, Results)),
    nil = beamtrace_oidc_flow_ffi:close(Store).
