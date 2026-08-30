%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_cli_preflight_tests).
-include_lib("eunit/include/eunit.hrl").

agent_beam_status_reports_a_missing_beam_test() ->
    with_agent_beam("/nonexistent/beamtrace_agent.beam", fun() ->
        ?assertMatch(
            {error, <<"agent_beam_invalid: ", _/binary>>},
            beamtrace_cli_ffi:agent_beam_status()
        )
    end).

agent_beam_status_reports_a_valid_beam_test() ->
    case os:getenv("BEAMTRACE_AGENT_BEAM") of
        false -> ok;
        Path ->
            ?assertEqual(
                {ok, unicode:characters_to_binary(Path)},
                beamtrace_cli_ffi:agent_beam_status()
            )
    end.

with_agent_beam(Value, Fun) ->
    Previous = os:getenv("BEAMTRACE_AGENT_BEAM"),
    true = os:putenv("BEAMTRACE_AGENT_BEAM", Value),
    try
        Fun()
    after
        case Previous of
            false -> os:unsetenv("BEAMTRACE_AGENT_BEAM");
            _ -> os:putenv("BEAMTRACE_AGENT_BEAM", Previous)
        end
    end.

bundled_record_resolves_commands_from_the_parent_path_test() ->
    with_environment([
        {"BEAMTRACE_BUNDLED_RUNTIME", "1"},
        {"BEAMTRACE_PARENT_PATH_SET", "1"},
        {"BEAMTRACE_PARENT_PATH", "/nonexistent-toolchain"}
    ], fun() ->
        ?assertEqual(
            {error, <<"executable_not_found: erl">>},
            beamtrace_cli_ffi:start_gated_command(
                [<<"erl">>, <<"-noshell">>],
                <<"beamtrace_parent_path_test@localhost">>,
                <<"beamtrace_parent_path_cookie">>,
                <<"erlang">>
            )
        )
    end).

with_environment(Pairs, Fun) ->
    Previous = [{Name, os:getenv(Name)} || {Name, _} <- Pairs],
    [os:putenv(Name, Value) || {Name, Value} <- Pairs],
    try
        Fun()
    after
        [case Old of
             false -> os:unsetenv(Name);
             _ -> os:putenv(Name, Old)
         end || {Name, Old} <- Previous]
    end.
