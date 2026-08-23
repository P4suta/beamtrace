%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_enrollment_store_tests).

-include_lib("eunit/include/eunit.hrl").

concurrent_consumers_get_exactly_one_success_test() ->
    {Store, Code} = beamtrace_enrollment_store_ffi:new_at(1000, 100),
    Parent = self(),
    PublicKey = binary:copy(<<16#aa>>, 32),
    Pids = [
        spawn(fun() ->
            receive go -> ok end,
            Parent ! beamtrace_enrollment_store_ffi:consume(Store, Code, PublicKey, 1050)
        end)
        || _ <- lists:seq(1, 20)
    ],
    [Pid ! go || Pid <- Pids],
    Results = [receive Result -> Result after 1000 -> timeout end || _ <- lists:seq(1, 20)],
    Successes = [Result || Result = {ok, _} <- Results],
    ?assertEqual(1, length(Successes)),
    ?assertEqual(19, length([Result || Result = {error, <<"already_used">>} <- Results])),
    beamtrace_enrollment_store_ffi:close(Store).

persistence_failure_does_not_consume_enrollment_code_test() ->
    Attempts = atomics:new(1, []),
    Persist = fun(_RelayId, _PublicKey, _EnrolledAtMs) ->
        case atomics:add_get(Attempts, 1, 1) of
            1 -> {error, <<"storage_unavailable">>};
            _ -> {ok, nil}
        end
    end,
    {Store, Code} = beamtrace_enrollment_store_ffi:new_with_relays_at(
        1000, 100, [], Persist
    ),
    PublicKey = binary:copy(<<16#aa>>, 32),
    ?assertEqual(
        {error, <<"storage_unavailable">>},
        beamtrace_enrollment_store_ffi:consume(Store, Code, PublicKey, 1050)
    ),
    ?assertMatch(
        {ok, {relay_record, _, <<"Ed25519">>, PublicKey}},
        beamtrace_enrollment_store_ffi:consume(Store, Code, PublicKey, 1051)
    ),
    ?assertEqual(2, atomics:get(Attempts, 1)),
    beamtrace_enrollment_store_ffi:close(Store).
