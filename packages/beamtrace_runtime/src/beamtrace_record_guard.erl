%% SPDX-License-Identifier: Apache-2.0 OR MIT
%%
%% This dependency-free module is loaded into a `record` child before its
%% normal boot arguments run. Build-tool helper VMs are left untouched. The
%% final target VM starts distribution, waits for BeamTrace to arm, and keeps
%% normal OTP shutdown alive until the collector has drained its last batch.
-module(beamtrace_record_guard).
-behaviour(application).

-export([prepare/0, activate/0, finish/0, start/2, prep_stop/1, stop/1]).

-define(APPLICATION, beamtrace_record_guard_app).
-define(FINAL_KEY, {?MODULE, final_target}).
-define(EPMD_OUTPUT_LIMIT, 4096).
-define(EPMD_READY_ATTEMPTS, 100).
-define(EPMD_START_TIMEOUT_MS, 5000).

prepare() ->
    case single_vm_wrapper() of
        true -> ok;
        false -> activate()
    end.

activate() ->
    case persistent_term:get(?FINAL_KEY, false) of
        true -> ok;
        false -> activate_once()
    end.

activate_once() ->
    case final_target() of
        false ->
            case single_vm_wrapper() of
                true -> erlang:error(record_trigger_module_unavailable);
                false -> ok
            end;
        true ->
            persistent_term:put(?FINAL_KEY, true),
            ok = start_distribution(),
            ok = start_guard_application(),
            wait_for_marker("BEAMTRACE_RECORD_GATE")
    end.

finish() ->
    case persistent_term:get(?FINAL_KEY, false) of
        true -> init:stop();
        false -> ok
    end.

start(_Type, _Arguments) ->
    Pid = spawn_link(fun guard_loop/0),
    {ok, Pid, nil}.

prep_stop(State) ->
    wait_for_marker("BEAMTRACE_RECORD_FINISH_GATE"),
    assert_capture_cleanup(),
    finish_wrapper_shutdown(State).

stop(_State) -> ok.

guard_loop() ->
    receive
        stop -> ok
    end.

final_target() ->
    case target_module() of
        {ok, Module} ->
            case single_vm_wrapper() of
                true ->
                    %% Mix and Rebar3 execute the project in their initial VM.
                    %% The parent performs a bounded compile first, so this VM
                    %% can load and arm the trigger before the task begins.
                    add_candidate_code_paths(Module),
                    target_loadable(Module);
                false ->
                    %% Gleam build helpers are escripts with no target code
                    %% path. A final VM either already sees the trigger or has
                    %% explicit -pa/-pz entries that expose application code
                    %% after this early eval.
                    case direct_vm() orelse target_visible(Module)
                        orelse has_code_path_argument() of
                        false -> false;
                        true ->
                            add_candidate_code_paths(Module),
                            target_loadable(Module)
                    end
            end;
        error -> false
    end.

target_loadable(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> true;
        {error, _Reason} -> false
    end.

single_vm_wrapper() ->
    case os:getenv("BEAMTRACE_RECORD_WRAPPER") of
        "mix" -> true;
        "rebar3" -> true;
        _ -> false
    end.

finish_wrapper_shutdown(State) ->
    case os:getenv("BEAMTRACE_RECORD_WRAPPER") of
        %% `rebar3 shell --eval` resumes inside the escript after init:stop/0.
        %% By then OTP's file and code servers may already be gone, causing a
        %% spurious 127 even though the target completed. The finish marker is
        %% released only after BeamTrace has detached and drained capture, so a
        %% clean halt here preserves the real target outcome without racing
        %% Rebar3's post-shutdown error reporter.
        "rebar3" -> erlang:halt(0);
        _ -> State
    end.

target_visible(Module) -> code:which(Module) =/= non_existing.

direct_vm() -> os:getenv("BEAMTRACE_RECORD_DIRECT_VM") =:= "1".

has_code_path_argument() ->
    init:get_argument(pa) =/= error orelse init:get_argument(pz) =/= error.

target_module() ->
    case os:getenv("BEAMTRACE_RECORD_TRIGGER_MODULE") of
        false -> error;
        [] -> error;
        Name ->
            case filename:basename(Name) =:= Name of
                true -> {ok, list_to_atom(Name)};
                false -> error
            end
    end.

add_candidate_code_paths(Module) ->
    Beam = atom_to_list(Module) ++ ".beam",
    Patterns = [
        filename:join(["build", "*", "erlang", "*", "ebin"]),
        filename:join([
            "build", "*", "erlang", "*", "_gleam_artefacts"
        ]),
        filename:join(["_build", "*", "lib", "*", "ebin"]),
        "ebin"
    ],
    Directories = lists:usort(lists:append([
        filelib:wildcard(Pattern) || Pattern <- Patterns
    ])),
    lists:foreach(fun(Directory) ->
        case filelib:is_regular(filename:join(Directory, Beam)) of
            true -> _ = code:add_patha(filename:absname(Directory));
            false -> ok
        end
    end, Directories).

start_distribution() ->
    Name = required_environment("BEAMTRACE_RECORD_NODE_NAME"),
    Domain = case required_environment("BEAMTRACE_RECORD_NAME_DOMAIN") of
        "shortnames" -> shortnames;
        "longnames" -> longnames;
        Other -> erlang:error({invalid_record_name_domain, Other})
    end,
    ok = ensure_epmd(),
    case net_kernel:start(list_to_atom(Name), #{name_domain => Domain}) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok;
        {error, Reason} -> erlang:error({record_distribution_failed, Reason})
    end.

%% `erl -sname` starts the native EPMD daemon when necessary, but a node that
%% becomes distributed later through net_kernel:start/2 does not. `record`
%% must defer distribution until the final target VM is known, so start EPMD
%% here through a resolved executable and an argv list (never a shell).
ensure_epmd() ->
    case application:get_env(kernel, epmd_module, erl_epmd) of
        erl_epmd -> ensure_native_epmd();
        _AlternativeDiscovery -> ok
    end.

ensure_native_epmd() ->
    case net_adm:names() of
        {ok, _Names} -> ok;
        {error, _Unavailable} ->
            StartResult = start_epmd_daemon(),
            case await_epmd_ready(?EPMD_READY_ATTEMPTS, unavailable) of
                ok -> ok;
                {error, LastReason} -> erlang:error({
                    record_epmd_start_failed, StartResult, LastReason
                })
            end
    end.

start_epmd_daemon() ->
    %% Let the platform's standard erl launcher bootstrap EPMD. In particular,
    %% erlexec uses a detached CreateProcess with handle inheritance disabled
    %% on Windows; spawning `epmd -daemon` as a port bypasses that boundary and
    %% leaves the daemon holding a caller's redirected stdout/stderr handles.
    case erl_executable_from_runtime() of
        false -> {error, erl_executable_not_found};
        Executable ->
            try
                Port = open_port(
                    {spawn_executable, Executable},
                    [
                        binary,
                        exit_status,
                        stderr_to_stdout,
                        use_stdio,
                        {args, epmd_bootstrap_arguments()},
                        {env, epmd_bootstrap_environment()}
                    ]
                ),
                collect_epmd_start(
                    Port,
                    <<>>,
                    erlang:monotonic_time(millisecond)
                        + ?EPMD_START_TIMEOUT_MS
                )
            catch
                Class:Reason -> {error, {Class, Reason}}
            end
    end.

erl_executable_from_runtime() ->
    case init:get_argument(bindir) of
        {ok, [[Bindir] | _]} -> os:find_executable("erl", Bindir);
        _ -> false
    end.

epmd_bootstrap_arguments() ->
    Name = "beamtrace_epmd_" ++ integer_to_list(
        erlang:unique_integer([positive, monotonic])
    ),
    ["-sname", Name, "-noshell", "-eval", "halt(0)."].

epmd_bootstrap_environment() ->
    [
        {"ERL_AFLAGS", false},
        {"ERL_FLAGS", false},
        {"ERL_ZFLAGS", false},
        {"BEAMTRACE_RECORD_GATE", false},
        {"BEAMTRACE_RECORD_FINISH_GATE", false},
        {"BEAMTRACE_RECORD_TRIGGER_MODULE", false},
        {"BEAMTRACE_RECORD_NODE_NAME", false},
        {"BEAMTRACE_RECORD_NAME_DOMAIN", false},
        {"BEAMTRACE_RECORD_GUARD_BEAM", false},
        {"BEAMTRACE_RECORD_DIRECT_VM", false},
        {"BEAMTRACE_RECORD_WRAPPER", false}
    ].

collect_epmd_start(Port, Output, Deadline) ->
    Remaining = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)
    ),
    receive
        {Port, {data, Data}} -> collect_epmd_start(
            Port, append_epmd_output(Output, Data), Deadline
        );
        {Port, {exit_status, Status}} -> {exit_status, Status, Output}
    after Remaining ->
        try port_close(Port) catch _:_ -> ok end,
        {error, {epmd_start_timeout, Output}}
    end.

append_epmd_output(Output, Data) ->
    Combined = <<Output/binary, Data/binary>>,
    Size = byte_size(Combined),
    case Size =< ?EPMD_OUTPUT_LIMIT of
        true -> Combined;
        false -> binary:part(
            Combined, Size - ?EPMD_OUTPUT_LIMIT, ?EPMD_OUTPUT_LIMIT
        )
    end.

await_epmd_ready(0, LastReason) -> {error, LastReason};
await_epmd_ready(Attempts, _LastReason) ->
    case net_adm:names() of
        {ok, _Names} -> ok;
        {error, Reason} ->
            timer:sleep(20),
            await_epmd_ready(Attempts - 1, Reason)
    end.

start_guard_application() ->
    Specification = {application, ?APPLICATION, [
        {description, "BeamTrace record shutdown guard"},
        {vsn, "1"},
        {modules, [?MODULE]},
        {registered, []},
        {applications, [kernel, stdlib]},
        {mod, {?MODULE, []}}
    ]},
    case application:load(Specification) of
        ok -> ok;
        {error, {already_loaded, ?APPLICATION}} -> ok;
        {error, LoadReason} ->
            erlang:error({record_guard_load_failed, LoadReason})
    end,
    case application:start(?APPLICATION, permanent) of
        ok -> ok;
        {error, {already_started, ?APPLICATION}} -> ok;
        {error, StartReason} ->
            erlang:error({record_guard_start_failed, StartReason})
    end.

wait_for_marker(Name) ->
    Path = required_environment(Name),
    wait_for_marker_path(Path).

wait_for_marker_path(Path) ->
    case file:read_file(Path) of
        {ok, _Content} -> ok;
        _ ->
            timer:sleep(10),
            wait_for_marker_path(Path)
    end.

required_environment(Name) ->
    case os:getenv(Name) of
        false -> erlang:error({missing_record_environment, Name});
        Value -> Value
    end.

assert_capture_cleanup() ->
    case os:getenv("BEAMTRACE_RECORD_ASSERT_CLEANUP") of
        "1" ->
            case {seq_trace:get_system_tracer(),
                  code:is_loaded(beamtrace_agent)} of
                {false, false} -> ok;
                _ -> erlang:halt(91)
            end;
        _ -> ok
    end.
