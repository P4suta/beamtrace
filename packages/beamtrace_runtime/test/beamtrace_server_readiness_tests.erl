%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_server_readiness_tests).

-include_lib("eunit/include/eunit.hrl").

-spec readiness_follows_signal_installation_test() -> ok.
readiness_follows_signal_installation_test() ->
    Before = gen_event:which_handlers(erl_signal_server),
    Listener = spawn(fun listener/0),
    try
        Ready = fun() ->
            ?assert(lists:any(
                fun shutdown_handler/1,
                gen_event:which_handlers(erl_signal_server)
            )),
            ?assertEqual({ok, self()}, beamtrace_server_ffi:handle_event(sigterm, self())),
            nil
        end,
        ?assertEqual({ok, nil}, beamtrace_server_ffi:await_shutdown(Listener, Ready)),
        ?assertEqual(Before, gen_event:which_handlers(erl_signal_server))
    after
        exit(Listener, kill)
    end.

-spec failed_readiness_restores_signals_and_monitors_test() -> ok.
failed_readiness_restores_signals_and_monitors_test() ->
    Before = gen_event:which_handlers(erl_signal_server),
    Monitors = process_info(self(), monitors),
    Listener = spawn(fun listener/0),
    try
        ?assertError(readiness_failed, beamtrace_server_ffi:await_shutdown(
            Listener, fun() -> erlang:error(readiness_failed) end
        )),
        ?assertEqual(Before, gen_event:which_handlers(erl_signal_server)),
        ?assertEqual(Monitors, process_info(self(), monitors))
    after
        exit(Listener, kill)
    end.

-spec shutdown_handler(gen_event:handler()) -> boolean().
shutdown_handler({beamtrace_server_ffi, Id}) when is_reference(Id) -> true;
shutdown_handler(_) -> false.

-spec listener() -> ok.
listener() -> receive stop -> ok end.
