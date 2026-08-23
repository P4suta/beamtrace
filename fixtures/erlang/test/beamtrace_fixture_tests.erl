%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_fixture_tests).
-include_lib("eunit/include/eunit.hrl").

call_crash_restart_test_() ->
    {setup,
        fun() ->
            {ok, Sup} = beamtrace_fixture_sup:start_link(),
            unlink(Sup),
            Sup
        end,
        fun(Sup) -> exit(Sup, shutdown) end,
        fun(_Sup) -> fun() ->
                ?assertEqual(42, beamtrace_fixture_worker:operation(21)),
                Before = whereis(beamtrace_fixture_worker),
                _ = try beamtrace_fixture_worker:crash() catch exit:_ -> crashed end,
                After = wait_for_restart(Before, 100),
                ?assert(is_pid(After)),
                ?assertNotEqual(Before, After),
                ?assertEqual(10, beamtrace_fixture_worker:operation(5))
            end
        end}.

wait_for_restart(Before, Attempts) when Attempts > 0 ->
    case whereis(beamtrace_fixture_worker) of
        Pid when is_pid(Pid), Pid =/= Before -> Pid;
        _ -> timer:sleep(10), wait_for_restart(Before, Attempts - 1)
    end;
wait_for_restart(_Before, 0) -> error(restart_timeout).
