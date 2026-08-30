%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_test_suite_ffi).

-export([run/1]).

run(<<"unit">>) -> run_modules(unit_modules());
run(<<"integration">>) -> run_modules(integration_modules());
run(_) -> false.

run_modules(Modules) ->
    Options = [
        verbose,
        no_tty,
        {report, {gleeunit_progress, [{colored, true}]}},
        {scale_timeouts, 10}
    ],
    eunit:test(Modules, Options) =:= ok.

unit_modules() ->
    Excluded = integration_modules(),
    [Module || Module <- discovered_modules(), not lists:member(Module, Excluded)].

integration_modules() ->
    [
        beamtrace_oidc_discovery_ffi_tests,
        record_process_test,
        server_test
    ].

discovered_modules() ->
    Gleam = [gleam_module(Path) || Path <- filelib:wildcard("test/**/*.gleam")],
    Erlang = [erlang_module(Path) || Path <- filelib:wildcard("test/**/*.erl")],
    lists:usort(Gleam ++ Erlang).

gleam_module(Path) ->
    Source = filename:rootname(Path, ".gleam"),
    Relative = case lists:prefix("test/", Source) of
        true -> lists:nthtail(5, Source);
        false -> Source
    end,
    list_to_atom(lists:flatten(string:replace(Relative, "/", "@", all))).

erlang_module(Path) ->
    list_to_atom(filename:basename(Path, ".erl")).
