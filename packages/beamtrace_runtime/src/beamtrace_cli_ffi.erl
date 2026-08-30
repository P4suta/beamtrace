%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_cli_ffi).
-behaviour(gen_event).

-include_lib("kernel/include/file.hrl").

-export([
    read_cookie_file/1,
    read_cookie_default/0,
    read_record_cookie/0,
    auto_record_node/0,
    demo_command/0,
    agent_beam_status/0,
    absolute_path/1,
    bundled_runtime/0,
    web_assets_status/0,
    write_text/2,
    random_secret/0,
    capture_id/0,
    default_archive_path/0,
    temporary_archive_path/0,
    path_exists/1,
    delete_file/1,
    web_root/0,
    doctor/3,
    terminal_interactive/0,
    confirm_seq_trace/0,
    run_command/1,
    start_gated_command/3,
    start_gated_command/4,
    start_gated_command/5,
    release_gated_command/1,
    release_gated_command_finish/1,
    await_gated_command/2,
    stop_gated_command/1,
    gated_command_running/1,
    record_shutdown_exit_code/0,
    halt/1
]).

-export([
    init/1,
    handle_event/2,
    handle_call/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(MAX_OUTPUT_TAIL_BYTES, 65536).
-define(RECORD_SHUTDOWN_GRACE_MS, 5000).
-define(RECORD_SHUTDOWN_KEY, {?MODULE, record_shutdown_exit_code}).
-define(WRAPPER_COMPILE_TIMEOUT_MS, 300000).

read_cookie_file(Path) when is_binary(Path) ->
    case file:read_file(Path) of
        {ok, Content} -> normalize_secret(Content);
        {error, Reason} -> {error, reason_binary({cookie_file, Reason})}
    end.

read_cookie_default() ->
    case os:getenv("BEAMTRACE_COOKIE") of
        false -> prompt_cookie();
        Value -> normalize_secret(unicode:characters_to_binary(Value))
    end.

read_record_cookie() ->
    case os:getenv("BEAMTRACE_COOKIE") of
        false -> {ok, binary:part(shared_random_hex(32), 0, 48)};
        Value -> normalize_secret(unicode:characters_to_binary(Value))
    end.

auto_record_node() ->
    case inet:gethostname() of
        {ok, Host} ->
            HostBinary = unicode:characters_to_binary(Host),
            case safe_host_token(HostBinary) of
                true ->
                    Random = binary:part(shared_random_hex(16), 0, 24),
                    {ok, <<"beamtrace_", Random/binary, "@", HostBinary/binary>>};
                false -> {error, <<"local hostname is unsafe for a short node name">>}
            end;
        {error, Reason} -> {error, reason_binary({hostname, Reason})}
    end.

%% The demo runs on the runtime that executes BeamTrace itself, so the bundled
%% archive needs no host Erlang. The fixture beam is staged into the private
%% record gate directory by start_gated_command/5.
demo_command() ->
    case {runtime_erl_executable(), code:get_object_code(beamtrace_demo_fixture)} of
        {false, _} -> {error, <<"erl executable was not found">>};
        {_, error} -> {error, <<"bundled demo fixture is unavailable">>};
        {Executable, _Object} ->
            {ok, [
                unicode:characters_to_binary(Executable),
                <<"-noshell">>,
                <<"-s">>, <<"beamtrace_demo_fixture">>, <<"run">>
            ]}
    end.

agent_beam_status() ->
    case beamtrace_relay:agent_binary() of
        {ok, _Beam, Filename, _Digest} ->
            {ok, unicode:characters_to_binary(Filename)};
        {error, agent_beam_unavailable} ->
            {error, <<"agent_beam_unavailable">>};
        {error, Reason} ->
            {error, <<"agent_beam_invalid: ", (reason_binary(Reason))/binary>>}
    end.

bundled_runtime() -> os:getenv("BEAMTRACE_BUNDLED_RUNTIME") =:= "1".

absolute_path(Path) when is_binary(Path) ->
    unicode:characters_to_binary(filename:absname(unicode:characters_to_list(Path))).

web_assets_status() ->
    case valid_web_assets() of
        true -> {ok, web_root()};
        false -> {error, <<"web_assets_unavailable">>}
    end.

runtime_erl_executable() ->
    case init:get_argument(bindir) of
        {ok, [[Bindir] | _]} ->
            case os:find_executable("erl", Bindir) of
                false -> os:find_executable("erl");
                Executable -> filename:absname(Executable)
            end;
        _ -> os:find_executable("erl")
    end.

prompt_cookie() ->
    try io:get_password("Distribution cookie: ") of
        eof -> {error, <<"distribution cookie was not provided">>};
        {error, Reason} -> {error, reason_binary({secure_prompt, Reason})};
        Value -> normalize_secret(unicode:characters_to_binary(Value))
    catch
        _:_ -> {error, <<"secure cookie prompt is unavailable; use --cookie-file or BEAMTRACE_COOKIE">>}
    end.

normalize_secret(Content) ->
    Trimmed = unicode:characters_to_binary(string:trim(binary_to_list(Content))),
    case byte_size(Trimmed) of
        0 -> {error, <<"distribution cookie is empty">>};
        Size when Size =< 255 -> {ok, Trimmed};
        _ -> {error, <<"distribution cookie exceeds 255 bytes">>}
    end.

write_text(Path, Content) when is_binary(Path), is_binary(Content) ->
    case file:write_file(Path, Content, [binary]) of
        ok -> {ok, nil};
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

random_secret() ->
    base64:encode('beamtrace_runtime@crypto':random_bytes(48)).

capture_id() ->
    Random = binary:part(shared_random_hex(16), 0, 24),
    <<"capture-", Random/binary>>.

default_archive_path() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    Stamp = lists:flatten(io_lib:format(
        "~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ",
        [Year, Month, Day, Hour, Minute, Second]
    )),
    available_archive_name("beamtrace-" ++ Stamp, 0).

available_archive_name(Base, Suffix) ->
    Candidate = case Suffix of
        0 -> Base ++ ".beamtrace";
        _ -> Base ++ "-" ++ integer_to_list(Suffix) ++ ".beamtrace"
    end,
    case file:read_link_info(Candidate) of
        {error, enoent} -> unicode:characters_to_binary(Candidate);
        _ -> available_archive_name(Base, Suffix + 1)
    end.

temporary_archive_path() ->
    Root = case temporary_root() of
        {ok, Value} -> Value;
        {error, _} -> filename:absname(".")
    end,
    Random = binary:part(shared_random_hex(16), 0, 24),
    Name = "beamtrace-demo-" ++ binary_to_list(Random) ++ ".beamtrace",
    unicode:characters_to_binary(filename:join(Root, Name)).

path_exists(Path) when is_binary(Path) ->
    case file:read_link_info(binary_to_list(Path)) of
        {error, enoent} -> false;
        _ -> true
    end;
path_exists(_Path) -> true.

delete_file(Path) when is_binary(Path) ->
    case file:delete(Path) of
        ok -> nil;
        {error, enoent} -> nil;
        {error, _} -> nil
    end;
delete_file(_Path) -> nil.

terminal_interactive() ->
    case {io:columns(standard_io), io:columns(standard_error)} of
        {{ok, _}, {ok, _}} -> true;
        _ -> false
    end.

confirm_seq_trace() ->
    Prompt =
        "BeamTrace exact capture acquires the VM-global seq_trace lease. "
        "Cleanup resets its label and can affect another seq_trace user.\n"
        "Continue for this run only? [y/N] ",
    _ = io:put_chars(standard_error, Prompt),
    case io:get_line(standard_io, "") of
        eof -> false;
        {error, _} -> false;
        Line ->
            Normalized = string:lowercase(string:trim(Line)),
            Normalized =:= "y" orelse Normalized =:= "yes"
    end.

doctor(Json, ProfileStatus, ConfiguredCookieFiles)
        when is_boolean(Json), is_binary(ProfileStatus),
             is_list(ConfiguredCookieFiles) ->
    _ = [code:ensure_loaded(Module) || Module <- [trace, seq_trace, zip, crypto]],
    Otp = erlang:system_info(otp_release),
    WordSize = erlang:system_info(wordsize),
    TraceSession = erlang:function_exported(trace, session_create, 3),
    TraceSystem = erlang:function_exported(trace, system, 3),
    SeqTrace = erlang:function_exported(seq_trace, set_system_tracer, 1),
    Zip = erlang:function_exported(zip, create, 3),
    Crypto = erlang:function_exported(crypto, hash, 2),
    AgentBeam = case beamtrace_relay:agent_binary() of
        {ok, _Beam, _Filename, _Digest} -> true;
        {error, _Reason} -> false
    end,
    Erl = executable_available("erl"),
    Gleam = executable_available("gleam"),
    Mix = executable_available("mix"),
    Rebar3 = executable_available("rebar3"),
    Epmd = executable_available("epmd"),
    Distribution = Erl andalso Epmd,
    CookieFiles = configured_cookie_files(ConfiguredCookieFiles),
    CookiePermissions = cookie_permission_status(CookieFiles),
    CookieFileCount = length(CookieFiles),
    RuntimeRoot = unicode:characters_to_binary(code:root_dir()),
    Bundled = bundled_runtime(),
    case Json of
        true -> doctor_json(
            Otp, WordSize, TraceSession, TraceSystem, SeqTrace, Zip, Crypto,
            AgentBeam, valid_web_assets(), Distribution, CookiePermissions,
            CookieFileCount, ProfileStatus, Erl, Gleam, Mix, Rebar3,
            Bundled, RuntimeRoot
        );
        false -> doctor_human(
            Otp, WordSize, TraceSession, TraceSystem, SeqTrace, Zip, Crypto,
            AgentBeam, valid_web_assets(), Distribution, CookiePermissions,
            CookieFileCount, ProfileStatus, Erl, Gleam, Mix, Rebar3,
            Bundled, RuntimeRoot
        )
    end;
doctor(_Json, _ProfileStatus, _ConfiguredCookieFiles) ->
    <<"BeamTrace doctor: invalid request\n">>.

doctor_human(
    Otp, WordSize, TraceSession, TraceSystem, SeqTrace, Zip, Crypto,
    AgentBeam, WebAssets, Distribution, CookiePermissions, CookieFileCount,
    ProfileStatus,
    Erl, Gleam, Mix, Rebar3, Bundled, RuntimeRoot
) ->
    unicode:characters_to_binary(io_lib:format(
        "BeamTrace doctor~n"
        "  OTP release: ~s~n"
        "  runtime root: ~ts~n"
        "  bundled runtime: ~p~n"
        "  word size: ~B bytes~n"
        "  isolated trace session: ~p~n"
        "  trace:system/3: ~p (OTP 27 uses system_monitor fallback)~n"
        "  seq_trace system tracer: ~p~n"
        "  ZIP storage: ~p~n"
        "  crypto: ~p~n"
        "  agent BEAM: ~s~n"
        "  web assets: ~s~n"
        "  distribution available: ~p~n"
        "  cookie file permissions: ~s~n"
        "  cookie files checked: ~B~n"
        "  project profile: ~s~n"
        "  executables: erl=~p gleam=~p mix=~p rebar3=~p~n",
        [Otp, RuntimeRoot, Bundled, WordSize, TraceSession, TraceSystem,
         SeqTrace, Zip, Crypto,
         status_word(AgentBeam), status_word(WebAssets), Distribution,
         CookiePermissions, CookieFileCount, ProfileStatus,
         Erl, Gleam, Mix, Rebar3]
    )).

doctor_json(
    Otp, WordSize, TraceSession, TraceSystem, SeqTrace, Zip, Crypto,
    AgentBeam, WebAssets, Distribution, CookiePermissions, CookieFileCount,
    ProfileStatus,
    Erl, Gleam, Mix, Rebar3, Bundled, RuntimeRoot
) ->
    unicode:characters_to_binary(io_lib:format(
        "{\"otp_release\":\"~s\",\"runtime_root\":~s,\"bundled_runtime\":~s,"
        "\"word_size\":~B,"
        "\"isolated_trace_session\":~s,\"trace_system\":~s,"
        "\"seq_trace\":~s,\"zip\":~s,\"crypto\":~s,"
        "\"agent_beam\":~s,\"web_assets\":~s,"
        "\"distribution\":~s,\"cookie_permissions\":\"~s\","
        "\"cookie_files_checked\":~B,"
        "\"profile\":\"~s\",\"executables\":{"
        "\"erl\":~s,\"gleam\":~s,\"mix\":~s,\"rebar3\":~s}}~n",
        [Otp, json_text(RuntimeRoot), json_bool(Bundled), WordSize,
         json_bool(TraceSession), json_bool(TraceSystem),
         json_bool(SeqTrace), json_bool(Zip), json_bool(Crypto),
         json_bool(AgentBeam), json_bool(WebAssets), json_bool(Distribution),
         CookiePermissions, CookieFileCount, ProfileStatus,
         json_bool(Erl), json_bool(Gleam),
         json_bool(Mix), json_bool(Rebar3)]
    )).

executable_available(Name) -> toolchain_executable(Name) =/= false.

toolchain_executable(Name) ->
    case {os:getenv("BEAMTRACE_BUNDLED_RUNTIME"), filename:pathtype(Name)} of
        {"1", relative} ->
            case {os:getenv("BEAMTRACE_PARENT_PATH_SET"), os:getenv("BEAMTRACE_PARENT_PATH")} of
                {"1", ParentPath} when is_list(ParentPath) ->
                    os:find_executable(Name, ParentPath);
                _ -> false
            end;
        _ -> os:find_executable(Name)
    end.

configured_cookie_files(Configured) ->
    case os:getenv("BEAMTRACE_COOKIE_FILE") of
        false -> lists:usort(Configured);
        Path -> lists:usort([
            unicode:characters_to_binary(Path) | Configured
        ])
    end.

cookie_permission_status([]) -> "not_configured";
cookie_permission_status(Paths) ->
    Statuses = [cookie_path_status(Path) || Path <- Paths],
    case {lists:member("invalid", Statuses),
          lists:member("too_permissive", Statuses), os:type()} of
        {true, _, _} -> "invalid";
        {_, true, _} -> "too_permissive";
        {false, false, {win32, _}} -> "regular";
        {false, false, _} -> "private"
    end.

cookie_path_status(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, mode = Mode}} ->
            case os:type() of
                {win32, _} -> "regular";
                _ when Mode band 8#077 =:= 0 -> "private";
                _ -> "too_permissive"
            end;
        _ -> "invalid"
    end.

json_bool(true) -> "true";
json_bool(false) -> "false".

json_text(Value) ->
    Escaped = lists:flatmap(fun
        ($") -> "\\\"";
        ($\\) -> "\\\\";
        (Char) when Char < 32 -> io_lib:format("\\u~4.16.0b", [Char]);
        (Char) -> [Char]
    end, unicode:characters_to_list(Value)),
    [$", Escaped, $"].

status_word(true) -> "valid";
status_word(false) -> "unavailable".

web_root() ->
    unicode:characters_to_binary(web_root_string()).

web_root_string() ->
    case os:getenv("BEAMTRACE_WEB_ROOT") of
        false -> "../beamtrace_web/dist";
        Value -> Value
    end.

valid_web_assets() ->
    Root = web_root_string(),
    filelib:is_regular(filename:join(Root, "index.html"))
        andalso filelib:is_regular(filename:join(Root, "beamtrace_web.js"))
        andalso filelib:is_regular(filename:join(Root, "styles.css")).

run_command([Program | Arguments]) ->
    ProgramString = binary_to_list(Program),
    case os:find_executable(ProgramString) of
        false -> {error, reason_binary({executable_not_found, Program})};
        Executable ->
            Port = open_port(
                {spawn_executable, Executable},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    use_stdio,
                    {args, [binary_to_list(Arg) || Arg <- Arguments]}
                ]
            ),
            collect_port(Port, <<>>)
    end;
run_command([]) ->
    {error, <<"record command is empty">>}.

start_gated_command(Command, Node, Cookie) ->
    start_gated_command(Command, Node, Cookie, <<>>).

start_gated_command(Command, Node, Cookie, TriggerModule) ->
    start_gated_command(Command, Node, Cookie, TriggerModule, []).

start_gated_command([Program | Arguments], Node, Cookie, TriggerModule, Staged)
        when is_binary(Node), is_binary(Cookie), is_binary(TriggerModule),
             is_list(Staged) ->
    case {command_launch(Program), record_flags(Node, Cookie),
          record_guard_binary(), staged_module_binaries(Staged)} of
        {{ok, {Executable, PrefixArguments}},
         {ok, {Flags, NodeName, NameDomain}},
         {ok, GuardBinary},
         {ok, StagedBinaries}} ->
            case prepare_wrapper_target(
                Program,
                Arguments,
                Executable,
                PrefixArguments,
                TriggerModule
            ) of
                {ok, PreparedArguments} -> start_prepared_gated_command(
                    Program,
                    PrefixArguments,
                    PreparedArguments,
                    Executable,
                    Flags,
                    NodeName,
                    NameDomain,
                    GuardBinary,
                    StagedBinaries,
                    TriggerModule
                );
                {error, Reason} -> {error, Reason}
            end;
        {{error, Reason}, _, _, _} -> {error, Reason};
        {_, {error, Reason}, _, _} -> {error, Reason};
        {_, _, {error, Reason}, _} -> {error, Reason};
        {_, _, _, {error, Reason}} -> {error, Reason}
    end;
start_gated_command([], _Node, _Cookie, _TriggerModule, _Staged) ->
    {error, <<"record command is empty">>};
start_gated_command(_Command, _Node, _Cookie, _TriggerModule, _Staged) ->
    {error, <<"invalid gated command">>}.

%% Only BeamTrace-owned modules may be staged next to the guard beam.
staged_module_binaries(Names) ->
    staged_module_binaries(Names, []).

staged_module_binaries([], Acc) -> {ok, lists:reverse(Acc)};
staged_module_binaries([Name | Rest], Acc) when is_binary(Name) ->
    case binary:match(Name, <<"beamtrace_">>) of
        {0, _} ->
            case code:get_object_code(binary_to_atom(Name, utf8)) of
                {Module, Binary, _Path} when is_binary(Binary) ->
                    staged_module_binaries(Rest, [{Module, Binary} | Acc]);
                error -> {error, <<"staged module is unavailable: ", Name/binary>>}
            end;
        _ -> {error, <<"staged module is not owned by BeamTrace: ", Name/binary>>}
    end;
staged_module_binaries(_Names, _Acc) ->
    {error, <<"invalid staged module list">>}.

start_prepared_gated_command(
        Program, PrefixArguments, Arguments, Executable, Flags, NodeName,
        NameDomain, GuardBinary, StagedBinaries, TriggerModule
    ) ->
    case create_gate_directory() of
        {error, Reason} -> {error, Reason};
        {ok, {Directory, Gate, FinishGate}} ->
            case write_child_beams(Directory, GuardBinary, StagedBinaries) of
                {error, Reason} ->
                    cleanup_gate_directory(Directory, Gate, FinishGate),
                    {error, reason_binary({guard_extract_failed, Reason})};
                {ok, GuardPath} ->
                    Existing = case os:getenv("ERL_AFLAGS") of
                        false -> "";
                        Value -> Value
                    end,
                    ExistingFinish = case os:getenv("ERL_ZFLAGS") of
                        false -> "";
                        FinishValue -> FinishValue
                    end,
                    StagedFlags = case StagedBinaries of
                        [] -> "";
                        _ -> " -pa " ++ Directory
                    end,
                    CombinedFlags = string:trim(
                        Flags ++ StagedFlags ++ " " ++ Existing
                    ),
                    CombinedFinishFlags = string:trim(
                        ExistingFinish ++ " -eval \""
                        ++ binary_to_list(finish_gate_expression()) ++ "\""
                    ),
                    try
                        Port = open_port(
                            {spawn_executable, Executable},
                            [
                                binary,
                                exit_status,
                                stderr_to_stdout,
                                use_stdio,
                                {args, [
                                    binary_to_list(Arg)
                                    || Arg <- PrefixArguments ++ Arguments
                                ]},
                                {env, record_child_environment([
                                    {"ERL_AFLAGS", CombinedFlags},
                                    {"ERL_ZFLAGS", CombinedFinishFlags},
                                    {"BEAMTRACE_RECORD_GATE", Gate},
                                    {"BEAMTRACE_RECORD_FINISH_GATE", FinishGate},
                                    {"BEAMTRACE_RECORD_TRIGGER_MODULE",
                                     binary_to_list(TriggerModule)},
                                    {"BEAMTRACE_RECORD_NODE_NAME", NodeName},
                                    {"BEAMTRACE_RECORD_NAME_DOMAIN", NameDomain},
                                    {"BEAMTRACE_RECORD_GUARD_BEAM", GuardPath},
                                    {"BEAMTRACE_RECORD_DIRECT_VM",
                                     direct_vm_marker(Executable)},
                                    {"BEAMTRACE_RECORD_WRAPPER",
                                     atom_to_list(wrapper_tool(Program))}
                                ]) ++ child_runtime_environment(
                                    Directory, StagedBinaries
                                )}
                            ]
                        ),
                        OsPid = port_os_pid(Port),
                        Owner = self(),
                        Guardian = spawn(fun() ->
                            cleanup_guardian(
                                Owner, Port, OsPid, Directory, Gate, FinishGate
                            )
                        end),
                        case await_guardian_start(Guardian) of
                            ok -> {ok, {gated_command, Port,
                                unicode:characters_to_binary(Directory),
                                unicode:characters_to_binary(Gate),
                                unicode:characters_to_binary(FinishGate),
                                Guardian, OsPid}};
                            {error, GuardianReason} ->
                                terminate_gated_port(Port, OsPid),
                                cleanup_gate_directory(
                                    Directory, Gate, FinishGate
                                ),
                                {error, reason_binary({
                                    signal_guardian_failed, GuardianReason
                                })}
                        end
                    catch
                        Class:StartReason ->
                            cleanup_gate_directory(Directory, Gate, FinishGate),
                            {error, reason_binary({
                                child_start_failed, Class, StartReason
                            })}
                    end
            end
    end.

prepare_wrapper_target(_Program, Arguments, _Executable, _Prefix, <<>>) ->
    {ok, Arguments};
prepare_wrapper_target(
        Program, Arguments, Executable, PrefixArguments, TriggerModule
    ) ->
    Tool = wrapper_tool(Program),
    case Tool of
        other -> {ok, Arguments};
        _ ->
            case prepare_wrapper_arguments(Tool, Arguments) of
                {error, Reason} -> {error, Reason};
                {ok, PreparedArguments} ->
                    case target_beam_available(TriggerModule) of
                        true -> {ok, PreparedArguments};
                        false -> compile_wrapper_target(
                            Tool,
                            Arguments,
                            PreparedArguments,
                            Executable,
                            PrefixArguments,
                            TriggerModule
                        )
                    end
            end
    end.

compile_wrapper_target(
        Tool, Arguments, PreparedArguments, Executable, PrefixArguments,
        TriggerModule
    ) ->
    CompileArguments = wrapper_compile_arguments(Tool, Arguments),
    case run_wrapper_compile(
        Executable, PrefixArguments ++ CompileArguments
    ) of
        {ok, {0, _Output}} ->
            case target_beam_available(TriggerModule) of
                true -> {ok, PreparedArguments};
                false -> {error, iolist_to_binary([
                    "record ", atom_to_list(Tool),
                    " compile did not produce trigger module ", TriggerModule
                ])}
            end;
        {ok, {Status, <<>>}} -> {error, iolist_to_binary([
            "record ", atom_to_list(Tool),
            " compile exited with status ", integer_to_list(Status)
        ])};
        {ok, {Status, Output}} -> {error, iolist_to_binary([
            "record ", atom_to_list(Tool),
            " compile exited with status ", integer_to_list(Status),
            "; output tail:\n", Output
        ])};
        {error, Reason} -> {error, iolist_to_binary([
            "record ", atom_to_list(Tool), " compile failed: ", Reason
        ])}
    end.

prepare_wrapper_arguments(mix, Arguments) ->
    case inject_mix_activation(Arguments) of
        {ok, Prepared} -> {ok, Prepared};
        error -> {error, <<"record supports Mix project VMs through mix run">>}
    end;
prepare_wrapper_arguments(rebar3, Arguments) ->
    case lists:member(<<"shell">>, Arguments) of
        true -> {ok, inject_rebar3_activation(Arguments)};
        false -> {error,
            <<"record supports Rebar3 project VMs through rebar3 shell">>}
    end;
prepare_wrapper_arguments(gleam, [<<"run">> | Rest]) ->
    case prepare_gleam_run_arguments(Rest, [], false) of
        {ok, PreparedRest, true} -> {ok, [<<"run">> | PreparedRest]};
        {ok, PreparedRest, false} -> {ok, [
            <<"run">>, <<"--target">>, <<"erlang">> | PreparedRest
        ]};
        {error, Reason} -> {error, Reason}
    end;
prepare_wrapper_arguments(gleam, _Arguments) ->
    {error, <<"record supports Gleam project VMs through gleam run">>}.

prepare_gleam_run_arguments([], Acc, TargetSeen) ->
    {ok, lists:reverse(Acc), TargetSeen};
prepare_gleam_run_arguments([<<"--">> | Rest], Acc, TargetSeen) ->
    {ok, lists:reverse(Acc) ++ [<<"--">> | Rest], TargetSeen};
prepare_gleam_run_arguments([Flag, Target | Rest], Acc, _TargetSeen)
        when Flag =:= <<"--target">>; Flag =:= <<"-t">> ->
    case Target of
        <<"erlang">> -> prepare_gleam_run_arguments(
            Rest, [Target, Flag | Acc], true
        );
        <<"javascript">> -> {error,
            <<"record requires gleam run --target erlang">>};
        _ -> {error, <<"record received an invalid Gleam target">>}
    end;
prepare_gleam_run_arguments([Flag], _Acc, _TargetSeen)
        when Flag =:= <<"--target">>; Flag =:= <<"-t">> ->
    {error, <<"record received a Gleam target flag without a value">>};
prepare_gleam_run_arguments(
        [<<"--target=erlang">> | Rest], Acc, _TargetSeen
    ) ->
    prepare_gleam_run_arguments(Rest, [<<"--target=erlang">> | Acc], true);
prepare_gleam_run_arguments(
        [<<"--target=javascript">> | _Rest], _Acc, _TargetSeen
    ) ->
    {error, <<"record requires gleam run --target erlang">>};
prepare_gleam_run_arguments([<<"-t=erlang">> | Rest], Acc, _TargetSeen) ->
    prepare_gleam_run_arguments(Rest, [<<"-t=erlang">> | Acc], true);
prepare_gleam_run_arguments(
        [<<"-t=javascript">> | _Rest], _Acc, _TargetSeen
    ) ->
    {error, <<"record requires gleam run --target erlang">>};
prepare_gleam_run_arguments([<<"--runtime">> | _Rest], _Acc, _TargetSeen) ->
    {error, <<"record requires the Erlang target, not a JavaScript runtime">>};
prepare_gleam_run_arguments(
        [<<"--runtime=", _/binary>> | _Rest], _Acc, _TargetSeen
    ) ->
    {error, <<"record requires the Erlang target, not a JavaScript runtime">>};
prepare_gleam_run_arguments([Argument | Rest], Acc, TargetSeen) ->
    prepare_gleam_run_arguments(Rest, [Argument | Acc], TargetSeen).

inject_mix_activation([<<"run">> | Rest]) ->
    {ok, [
        <<"run">>, <<"-e">>, <<":beamtrace_record_guard.activate()">>
        | Rest
    ]};
inject_mix_activation([Argument | Rest]) ->
    case inject_mix_activation(Rest) of
        {ok, Prepared} -> {ok, [Argument | Prepared]};
        error -> error
    end;
inject_mix_activation([]) -> error.

inject_rebar3_activation([<<"--eval">>, Expression | Rest]) ->
    [
        <<"--eval">>,
        <<"beamtrace_record_guard:activate(), ", Expression/binary>>
        | Rest
    ];
inject_rebar3_activation([Argument | Rest]) ->
    [Argument | inject_rebar3_activation(Rest)];
inject_rebar3_activation([]) ->
    [<<"--eval">>, <<"beamtrace_record_guard:activate().">>].

wrapper_compile_arguments(rebar3, [<<"as">>, Profile | _]) ->
    [<<"as">>, Profile, <<"compile">>];
wrapper_compile_arguments(gleam, _Arguments) ->
    [<<"build">>, <<"--target">>, <<"erlang">>, <<"--no-print-progress">>];
wrapper_compile_arguments(_Tool, _Arguments) -> [<<"compile">>].

run_wrapper_compile(Executable, Arguments) ->
    try
        Port = open_port(
            {spawn_executable, Executable},
            [
                binary,
                exit_status,
                stderr_to_stdout,
                use_stdio,
                {args, [binary_to_list(Arg) || Arg <- Arguments]},
                {env, record_child_environment([])}
            ]
        ),
        OsPid = port_os_pid(Port),
        collect_port_until(
            Port,
            <<>>,
            erlang:monotonic_time(millisecond)
                + ?WRAPPER_COMPILE_TIMEOUT_MS,
            OsPid
        )
    catch
        Class:Reason -> {error, reason_binary({child_compile_failed, Class, Reason})}
    end.

target_beam_available(TriggerModule) when is_binary(TriggerModule) ->
    Name = binary_to_list(TriggerModule),
    case Name =/= [] andalso filename:basename(Name) =:= Name of
        false -> false;
        true ->
            Beam = Name ++ ".beam",
            Patterns = [
                filename:join(["build", "*", "erlang", "*", "ebin"]),
                filename:join([
                    "build", "*", "erlang", "*", "_gleam_artefacts"
                ]),
                filename:join(["_build", "*", "lib", "*", "ebin"]),
                "ebin"
            ],
            lists:any(fun(Directory) ->
                filelib:is_regular(filename:join(Directory, Beam))
            end, lists:append([filelib:wildcard(Pattern) || Pattern <- Patterns]))
    end.

wrapper_tool(Program) when is_binary(Program) ->
    Name = string:lowercase(filename:basename(binary_to_list(Program))),
    Stem = case filename:extension(Name) of
        ".exe" -> filename:rootname(Name);
        ".cmd" -> filename:rootname(Name);
        ".bat" -> filename:rootname(Name);
        _ -> Name
    end,
    case Stem of
        "gleam" -> gleam;
        "mix" -> mix;
        "rebar3" -> rebar3;
        _ -> other
    end.

port_os_pid(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} when is_integer(OsPid), OsPid > 1 -> OsPid;
        _ -> undefined
    end.

record_child_environment(Base) ->
    case os:getenv("BEAMTRACE_BUNDLED_RUNTIME") of
        "1" ->
            RuntimeNames = [
                "PATH", "ERL_ROOTDIR", "ROOTDIR", "ERL_LIBS",
                "BINDIR", "EMU", "PROGNAME", "ESCRIPT_NAME"
            ],
            Base
            ++ [restored_parent_environment(Name) || Name <- RuntimeNames]
            ++ [
                {"BEAMTRACE_AGENT_BEAM", false},
                {"BEAMTRACE_WEB_ROOT", false},
                {"BEAMTRACE_BUNDLED_RUNTIME", false}
            ]
            ++ lists:append([
                [{parent_set_marker(Name), false},
                 {parent_value_marker(Name), false}]
                || Name <- RuntimeNames
            ]);
        _ -> Base
    end.

restored_parent_environment(Target) ->
    SetMarker = parent_set_marker(Target),
    ValueMarker = parent_value_marker(Target),
    case os:getenv(SetMarker) of
        "1" ->
            case os:getenv(ValueMarker) of
                false -> {Target, false};
                Value -> {Target, Value}
            end;
        _ -> {Target, false}
    end.

parent_set_marker(Target) ->
    "BEAMTRACE_PARENT_" ++ Target ++ "_SET".

parent_value_marker(Target) ->
    "BEAMTRACE_PARENT_" ++ Target.

release_gated_command(
        {gated_command, Port, _Directory, Gate, _FinishGate, _Guardian, _OsPid}
    )
        when is_port(Port), is_binary(Gate) ->
    case create_marker(binary_to_list(Gate)) of
        ok -> {ok, nil};
        {error, eexist} -> {ok, nil};
        {error, Reason} -> {error, reason_binary({gate_release_failed, Reason})}
    end;
release_gated_command(_Handle) -> {error, <<"invalid gated command">>}.

release_gated_command_finish(
    {gated_command, Port, _Directory, _Gate, FinishGate, _Guardian, _OsPid}
) when is_port(Port), is_binary(FinishGate) ->
    case record_shutdown_exit_code() of
        0 ->
            case create_marker(binary_to_list(FinishGate)) of
                ok -> {ok, nil};
                {error, eexist} -> {ok, nil};
                {error, Reason} ->
                    {error, reason_binary({finish_gate_release_failed, Reason})}
            end;
        _SignalStatus -> {ok, nil}
    end;
release_gated_command_finish(_Handle) -> {error, <<"invalid gated command">>}.

await_gated_command(
        {gated_command, Port, Directory, Gate, FinishGate, Guardian, OsPid},
        TimeoutMs
    )
        when is_port(Port), is_binary(Directory), is_binary(Gate),
             is_binary(FinishGate),
             is_pid(Guardian),
             is_integer(TimeoutMs), TimeoutMs > 0, TimeoutMs =< 86400000 ->
    Result = append_crash_dump_slogan(
        collect_port_until(
            Port,
            <<>>,
            erlang:monotonic_time(millisecond) + TimeoutMs,
            OsPid
        ),
        binary_to_list(Directory)
    ),
    stop_cleanup_guardian(Guardian),
    cleanup_gate_directory(
        binary_to_list(Directory),
        binary_to_list(Gate),
        binary_to_list(FinishGate)
    ),
    Result;
await_gated_command(_Handle, _TimeoutMs) ->
    {error, <<"invalid child timeout">>}.

stop_gated_command(
        {gated_command, Port, Directory, Gate, FinishGate, Guardian, OsPid}
    )
        when is_port(Port), is_binary(Directory), is_binary(Gate),
             is_binary(FinishGate),
             is_pid(Guardian) ->
    terminate_gated_port(Port, OsPid),
    stop_cleanup_guardian(Guardian),
    cleanup_gate_directory(
        binary_to_list(Directory),
        binary_to_list(Gate),
        binary_to_list(FinishGate)
    ),
    nil;
stop_gated_command(_Handle) -> nil.

gated_command_running(
        {gated_command, Port, _Directory, _Gate, _FinishGate, _Guardian, _OsPid}
    )
        when is_port(Port) ->
    case erlang:port_info(Port) of
        undefined -> false;
        _ -> true
    end;
gated_command_running(_Handle) -> false.

%% The application command must come from the user's toolchain. Inside the
%% release archive erlexec prepends the bundled ERTS to PATH, so resolve
%% against the PATH the launcher saw instead.
command_executable(Program) when is_binary(Program) ->
    case toolchain_executable(binary_to_list(Program)) of
        false -> {error, <<"executable_not_found: ", Program/binary>>};
        %% Keep the resolved absolute command path, including its final shim or
        %% symlink name. mise/asdf dispatch on argv[0]; dereferencing the shim
        %% to the tool manager binary changes command semantics.
        Executable -> {ok, filename:absname(Executable)}
    end.

command_launch(Program) ->
    case command_executable(Program) of
        {error, Reason} -> {error, Reason};
        {ok, Executable} ->
            case {os:type(), string:lowercase(filename:extension(Executable))} of
                {{win32, _}, ".cmd"} -> windows_script_launch(
                    wrapper_tool(Program), Executable
                );
                {{win32, _}, ".bat"} -> windows_script_launch(
                    wrapper_tool(Program), Executable
                );
                _ -> {ok, {Executable, []}}
            end
    end.

windows_script_launch(rebar3, Script) ->
    case {os:find_executable("escript.exe"), rebar3_escript(Script)} of
        {false, _} -> {error,
            <<"escript.exe is required for shellless Rebar3 record">>};
        {_, error} -> {error,
            <<"could not resolve the Rebar3 escript behind its Windows launcher">>};
        {Escript, {ok, Rebar3}} -> {ok, {
            filename:absname(Escript),
            [unicode:characters_to_binary(Rebar3)]
        }}
    end;
windows_script_launch(mix, Script) ->
    BinDirectory = filename:dirname(Script),
    MixScript = filename:join(BinDirectory, "mix"),
    ElixirRoot = filename:absname(filename:join(BinDirectory, "../lib")),
    ElixirEbin = filename:join([ElixirRoot, "elixir", "ebin"]),
    case {
        os:find_executable("erl.exe"),
        filelib:is_regular(MixScript),
        filelib:is_dir(ElixirEbin)
    } of
        {false, _, _} -> {error,
            <<"erl.exe is required for shellless Mix record">>};
        {_, false, _} -> {error,
            <<"could not resolve the Mix script behind its Windows launcher">>};
        {_, _, false} -> {error,
            <<"could not resolve the Elixir runtime behind its Windows launcher">>};
        {Erl, true, true} -> {ok, {
            filename:absname(Erl),
            [
                <<"-noshell">>,
                <<"-elixir_root">>, unicode:characters_to_binary(ElixirRoot),
                <<"-pa">>, unicode:characters_to_binary(ElixirEbin),
                <<"-s">>, <<"elixir">>, <<"start_cli">>,
                <<"-extra">>, unicode:characters_to_binary(MixScript)
            ]
        }}
    end;
windows_script_launch(_Tool, _Script) ->
    {error,
        <<"record refuses Windows command scripts; pass a native executable">>}.

rebar3_escript(Script) ->
    Sibling = filename:rootname(Script),
    RepositoryTool = filename:absname(filename:join([
        filename:dirname(Script), "..", ".tools", "rebar3"
    ])),
    case filelib:is_regular(Sibling) of
        true -> {ok, Sibling};
        false ->
            case filelib:is_regular(RepositoryTool) of
                true -> {ok, RepositoryTool};
                false -> error
            end
    end.

direct_vm_marker(Executable) ->
    Candidates = [
        Candidate
        || Candidate <- [os:find_executable("erl"), runtime_erl_executable()],
           Candidate =/= false
    ],
    case lists:any(fun(Candidate) ->
        same_executable(Executable, filename:absname(Candidate))
    end, Candidates) of
        true -> "1";
        false -> "0"
    end.

%% Crash dumps belong to the private gate directory, never to the user's
%% working directory; their slogan is reported through the output tail.
%% Staged launches also run on BeamTrace's own runtime root.
child_runtime_environment(Directory, StagedBinaries) ->
    CrashDump = case os:getenv("ERL_CRASH_DUMP") of
        false -> [{"ERL_CRASH_DUMP", crash_dump_path(Directory)}];
        _Explicit -> []
    end,
    RootDir = case StagedBinaries of
        [] -> [];
        _ -> [{"ERL_ROOTDIR", code:root_dir()}]
    end,
    CrashDump ++ RootDir.

crash_dump_path(Directory) -> filename:join(Directory, "erl_crash.dump").

crash_dump_slogan(Directory) ->
    case file:read_file(crash_dump_path(Directory)) of
        {ok, Dump} ->
            case re:run(Dump, <<"^Slogan: (.*)$">>, [multiline, {capture, [1], binary}]) of
                {match, [Slogan]} -> {ok, Slogan};
                nomatch -> error
            end;
        {error, _} -> error
    end.

append_crash_dump_slogan({ok, {Status, Output}}, Directory) when Status =/= 0 ->
    case crash_dump_slogan(Directory) of
        {ok, Slogan} -> {ok, {Status, append_output_tail(
            Output, <<"\ncrash dump slogan: ", Slogan/binary, "\n">>
        )}};
        error -> {ok, {Status, Output}}
    end;
append_crash_dump_slogan(Result, _Directory) -> Result.

same_executable(Left, Right) when Left =:= Right -> true;
same_executable(Left, Right) ->
    case {file:read_file_info(Left), file:read_file_info(Right)} of
        {{ok, #file_info{major_device = Device, inode = Inode}},
         {ok, #file_info{major_device = Device, inode = Inode}}}
                when Inode =/= 0 -> true;
        _ -> false
    end.

record_flags(Node, Cookie) ->
    case {record_node_parts(Node), safe_flag_token(Cookie)} of
        {{ok, {Name, Host}}, true} ->
            {NodeName, NameDomain} = case binary:match(Host, <<".">>) of
                nomatch -> {binary_to_list(Name), "shortnames"};
                _ -> {binary_to_list(Node), "longnames"}
            end,
            {ok, {
                "-setcookie " ++ binary_to_list(Cookie)
                    ++ " -eval \""
                    ++ binary_to_list(start_gate_expression()) ++ "\"",
                NodeName,
                NameDomain
            }};
        {{error, Reason}, _} -> {error, Reason};
        {_, false} -> {error, <<"record cookie contains unsafe flag characters">>}
    end.

record_node_parts(Node) when is_binary(Node), byte_size(Node) > 2, byte_size(Node) =< 255 ->
    case binary:split(Node, <<"@">>, [global]) of
        [Name, Host] when byte_size(Name) > 0, byte_size(Host) > 0 ->
            case safe_flag_token(Name) andalso safe_host_token(Host) of
                true -> {ok, {Name, Host}};
                false -> {error, <<"record node contains unsafe flag characters">>}
            end;
        _ -> {error, <<"record node must be name@host">>}
    end;
record_node_parts(_Node) -> {error, <<"record node must be name@host">>}.

safe_flag_token(Value) when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 255 ->
    lists:all(fun(Char) ->
        (Char >= $a andalso Char =< $z)
        orelse (Char >= $A andalso Char =< $Z)
        orelse (Char >= $0 andalso Char =< $9)
        orelse Char =:= $_
        orelse Char =:= $-
    end, binary_to_list(Value));
safe_flag_token(_Value) -> false.

safe_host_token(Value) when is_binary(Value), byte_size(Value) > 0 ->
    lists:all(fun(Char) ->
        (Char >= $a andalso Char =< $z)
        orelse (Char >= $A andalso Char =< $Z)
        orelse (Char >= $0 andalso Char =< $9)
        orelse Char =:= $_
        orelse Char =:= $-
        orelse Char =:= $.
    end, binary_to_list(Value));
safe_host_token(_Value) -> false.

start_gate_expression() ->
    <<"Path = os:getenv([$B,$E,$A,$M,$T,$R,$A,$C,$E,$_,"
      "$R,$E,$C,$O,$R,$D,$_, $G,$U,$A,$R,$D,$_, $B,$E,$A,$M]), "
      "{ok, Binary} = file:read_file(Path), "
      "{module, beamtrace_record_guard} = code:load_binary("
      "beamtrace_record_guard, Path, Binary), "
      "beamtrace_record_guard:prepare().">>.

finish_gate_expression() ->
    <<"beamtrace_record_guard:finish().">>.

record_guard_binary() ->
    case code:get_object_code(beamtrace_record_guard) of
        {beamtrace_record_guard, Binary, _Path} when is_binary(Binary) ->
            {ok, Binary};
        error -> {error, <<"record shutdown guard is unavailable">>}
    end.

collect_port_until(Port, Acc, Deadline, OsPid) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            collect_port_until(
                Port, append_output_tail(Acc, Data), Deadline, OsPid
            );
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc}}
    after Remaining ->
        terminate_gated_port(Port, OsPid),
        {error, timeout_error(Acc)}
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect_port(Port, append_output_tail(Acc, Data));
        {Port, {exit_status, Status}} ->
            {ok, {Status, Acc}}
    after 86400000 ->
        try port_close(Port)
        catch _:_ -> ok
        end,
        {error, timeout_error(Acc)}
    end.

create_gate_directory() ->
    case temporary_root() of
        {error, Reason} -> {error, Reason};
        {ok, Base} -> create_gate_directory_in(Base)
    end.

create_gate_directory_in(Base) ->
    Name = "beamtrace-record-" ++ binary_to_list(
        binary:part(shared_random_hex(16), 0, 24)
    ),
    Directory = filename:join(Base, Name),
    Gate = filename:join(Directory, "start.gate"),
    FinishGate = filename:join(Directory, "finish.gate"),
    case file:make_dir(Directory) of
        ok ->
            case file:change_mode(Directory, 8#700) of
                ok -> {ok, {Directory, Gate, FinishGate}};
                {error, Reason} ->
                    _ = file:del_dir(Directory),
                    {error, reason_binary({temp_directory_permissions, Reason})}
            end;
        {error, Reason} ->
            {error, reason_binary({temp_directory_create_failed, Reason})}
    end.

temporary_root() ->
    Candidates = case os:type() of
        {win32, _} ->
            [os:getenv("TMPDIR"), os:getenv("TEMP"), os:getenv("TMP")];
        _ ->
            [os:getenv("TMPDIR"), os:getenv("TMP"), os:getenv("TEMP"), "/tmp"]
    end,
    first_temp_root(Candidates).

first_temp_root([false | Rest]) -> first_temp_root(Rest);
first_temp_root([[] | Rest]) -> first_temp_root(Rest);
first_temp_root([Root | Rest]) ->
    Absolute = filename:absname(Root),
    case filelib:is_dir(Absolute) of
        true -> {ok, Absolute};
        false -> first_temp_root(Rest)
    end;
first_temp_root([]) -> {error, <<"temporary_directory_unavailable">>}.

write_child_beams(Directory, GuardBinary, StagedBinaries) ->
    Path = filename:join(Directory, "guard.beam"),
    case create_private_file(Path, GuardBinary) of
        ok -> write_staged_beams(Directory, StagedBinaries, Path);
        {error, Reason} -> {error, Reason}
    end.

write_staged_beams(_Directory, [], GuardPath) -> {ok, GuardPath};
write_staged_beams(Directory, [{Module, Binary} | Rest], GuardPath) ->
    Path = filename:join(Directory, atom_to_list(Module) ++ ".beam"),
    case create_private_file(Path, Binary) of
        ok -> write_staged_beams(Directory, Rest, GuardPath);
        {error, Reason} -> {error, Reason}
    end.

create_marker(Path) -> create_private_file(Path, <<"release">>).

create_private_file(Path, Content) ->
    case file:open(Path, [write, binary, exclusive]) of
        {ok, File} ->
            Permissions = file:change_mode(Path, 8#600),
            Result = case Permissions of
                ok -> file:write(File, Content);
                {error, PermissionReason} -> {error, PermissionReason}
            end,
            Close = file:close(File),
            case {Result, Close} of
                {ok, ok} -> ok;
                {{error, Reason}, _} -> {error, Reason};
                {_, {error, Reason}} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

cleanup_guardian(Owner, Port, OsPid, Directory, Gate, FinishGate) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    Handler = {?MODULE, make_ref()},
    case install_guardian_signal_handler(Handler, self()) of
        {ok, Installation} ->
            Owner ! {self(), guardian_ready},
            cleanup_guardian_loop(
                Owner,
                OwnerMonitor,
                Handler,
                Installation,
                Port,
                OsPid,
                Directory,
                Gate,
                FinishGate
            );
        {error, Reason} ->
            Owner ! {self(), {guardian_error, Reason}},
            erlang:demonitor(OwnerMonitor, [flush]),
            terminate_gated_port(Port, OsPid),
            cleanup_gate_directory(Directory, Gate, FinishGate)
    end.

cleanup_guardian_loop(
        Owner, OwnerMonitor, Handler, Installation, Port, OsPid,
        Directory, Gate, FinishGate
    ) ->
    receive
        stop ->
            restore_guardian_signal_handler(Handler, Installation);
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            restore_guardian_signal_handler(Handler, Installation),
            terminate_gated_port(Port, OsPid);
        {beamtrace_record_shutdown, Signal}
                when Signal =:= sigint; Signal =:= sigterm ->
            Status = signal_exit_status(Signal),
            %% Publish the requested status before terminating the child. The
            %% CLI can then cancel and close capture without racing a removed
            %% finish gate, while halt/1 prevents any later diagnostic path
            %% from replacing 130/143 with a generic exit code.
            persistent_term:put(?RECORD_SHUTDOWN_KEY, Status),
            restore_guardian_signal_handler(Handler, Installation),
            terminate_gated_port(Port, OsPid),
            cleanup_gate_directory(Directory, Gate, FinishGate),
            await_record_owner_shutdown(OwnerMonitor, Owner, Status)
    end,
    cleanup_gate_directory(Directory, Gate, FinishGate).

await_record_owner_shutdown(OwnerMonitor, Owner, Status) ->
    receive
        stop -> ok;
        {'DOWN', OwnerMonitor, process, Owner, _Reason} -> erlang:halt(Status)
    after ?RECORD_SHUTDOWN_GRACE_MS ->
        erlang:halt(Status)
    end.

await_guardian_start(Guardian) ->
    receive
        {Guardian, guardian_ready} -> ok;
        {Guardian, {guardian_error, Reason}} -> {error, Reason}
    after 5000 ->
        exit(Guardian, kill),
        {error, timeout}
    end.

stop_cleanup_guardian(Guardian) when is_pid(Guardian) ->
    Monitor = erlang:monitor(process, Guardian),
    Guardian ! stop,
    receive
        {'DOWN', Monitor, process, Guardian, _Reason} -> ok
    after 5000 ->
        exit(Guardian, kill),
        receive
            {'DOWN', Monitor, process, Guardian, _Reason} -> ok
        after 1000 -> erlang:demonitor(Monitor, [flush])
        end
    end;
stop_cleanup_guardian(_Guardian) -> ok.

install_guardian_signal_handler(Handler, Owner) ->
    try
        case os:type() of
            {unix, _} ->
                ok = os:set_signal(sigterm, handle),
                case lists:member(
                    erl_signal_handler,
                    gen_event:which_handlers(erl_signal_server)
                ) of
                    true ->
                        case gen_event:swap_handler(
                            erl_signal_server,
                            {erl_signal_handler, beamtrace_record},
                            {Handler, Owner}
                        ) of
                            ok -> {ok, swapped_default};
                            Error -> Error
                        end;
                    false ->
                        case gen_event:add_handler(
                            erl_signal_server, Handler, Owner
                        ) of
                            ok -> {ok, added};
                            Error -> Error
                        end
                end;
            {win32, _} ->
                case gen_event:add_handler(
                    erl_signal_server, Handler, Owner
                ) of
                    ok -> {ok, added};
                    Error -> Error
                end
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

restore_guardian_signal_handler(Handler, swapped_default) ->
    _ = try gen_event:swap_handler(
            erl_signal_server,
            {Handler, normal},
            {erl_signal_handler, []}
        )
        catch _:_ -> ok
        end,
    ok;
restore_guardian_signal_handler(Handler, added) ->
    _ = try gen_event:delete_handler(
            erl_signal_server, Handler, normal
        )
        catch _:_ -> ok
        end,
    ok.

terminate_gated_port(Port, OsPid) ->
    case {os:type(), OsPid} of
        {{win32, _}, Pid} when is_integer(Pid), Pid > 1 ->
            _ = run_command([
                <<"taskkill">>,
                <<"/PID">>,
                integer_to_binary(Pid),
                <<"/T">>,
                <<"/F">>
            ]);
        {{unix, _}, Pid} when is_integer(Pid), Pid > 1 ->
            ProcessTree = unix_process_tree(Pid),
            _ = signal_processes("-TERM", ProcessTree),
            timer:sleep(100),
            _ = signal_processes("-KILL", ProcessTree);
        _ -> ok
    end,
    try port_close(Port) catch _:_ -> ok end,
    ok.

unix_process_tree(Root) ->
    case run_command([<<"ps">>, <<"-axo">>, <<"pid=,ppid=">>]) of
        {ok, {0, Output}} ->
            [Root
             | descendants(
                 [Root], parse_process_pairs(Output), #{Root => true}, []
             )];
        _ -> [Root]
    end.

parse_process_pairs(Output) ->
    lists:filtermap(fun(Line) ->
        case string:tokens(Line, " \t") of
            [PidSource, ParentSource] ->
                case {string:to_integer(PidSource),
                      string:to_integer(ParentSource)} of
                    {{Pid, []}, {Parent, []}}
                            when Pid > 1, Parent >= 0 ->
                        {true, {Pid, Parent}};
                    _ -> false
                end;
            _ -> false
        end
    end, string:split(binary_to_list(Output), "\n", all)).

descendants([], _Pairs, _Seen, Acc) -> Acc;
descendants(Parents, Pairs, Seen, Acc) ->
    Children = lists:usort([
        Pid
        || {Pid, Parent} <- Pairs,
           lists:member(Parent, Parents),
           not maps:is_key(Pid, Seen)
    ]),
    NextSeen = lists:foldl(fun(Pid, Map) -> Map#{Pid => true} end, Seen, Children),
    descendants(Children, Pairs, NextSeen, Children ++ Acc).

signal_processes(_Signal, []) -> ok;
signal_processes(Signal, Pids) ->
    Arguments = [unicode:characters_to_binary(Signal)]
        ++ [integer_to_binary(Pid) || Pid <- Pids],
    _ = run_command([<<"kill">> | Arguments]),
    ok.

cleanup_gate_directory(Directory, Gate, FinishGate) ->
    _ = file:delete(Gate),
    _ = file:delete(FinishGate),
    _ = file:delete(filename:join(Directory, "guard.beam")),
    _ = file:delete(crash_dump_path(Directory)),
    _ = [file:delete(Beam) || Beam <- filelib:wildcard(
        filename:join(Directory, "beamtrace_*.beam")
    )],
    _ = file:del_dir(Directory),
    ok.

signal_exit_status(sigint) -> 130;
signal_exit_status(sigterm) -> 143.

append_output_tail(Acc, Data) ->
    Combined = <<Acc/binary, Data/binary>>,
    Size = byte_size(Combined),
    case Size =< ?MAX_OUTPUT_TAIL_BYTES of
        true -> Combined;
        false -> binary:part(
            Combined,
            Size - ?MAX_OUTPUT_TAIL_BYTES,
            ?MAX_OUTPUT_TAIL_BYTES
        )
    end.

timeout_error(<<>>) -> <<"record command timed out">>;
timeout_error(Output) ->
    <<"record command timed out; output tail:\n", Output/binary>>.

init(Owner) when is_pid(Owner) -> {ok, Owner};
init({Owner, _PreviousHandlerState}) when is_pid(Owner) -> {ok, Owner}.

handle_event(sigint, Owner) ->
    Owner ! {beamtrace_record_shutdown, sigint},
    {ok, Owner};
handle_event(sigterm, Owner) ->
    Owner ! {beamtrace_record_shutdown, sigterm},
    {ok, Owner};
handle_event({signal, sigint}, Owner) ->
    Owner ! {beamtrace_record_shutdown, sigint},
    {ok, Owner};
handle_event({signal, sigterm}, Owner) ->
    Owner ! {beamtrace_record_shutdown, sigterm},
    {ok, Owner};
handle_event(_Event, Owner) -> {ok, Owner}.

handle_call(_Request, Owner) -> {ok, ok, Owner}.
handle_info(_Info, Owner) -> {ok, Owner}.
terminate(_Reason, _Owner) -> ok.
code_change(_OldVersion, Owner, _Extra) -> {ok, Owner}.

record_shutdown_exit_code() ->
    case persistent_term:get(?RECORD_SHUTDOWN_KEY, 0) of
        Status when Status =:= 130; Status =:= 143 -> Status;
        _ -> 0
    end.

halt(Code) when is_integer(Code) ->
    case record_shutdown_exit_code() of
        0 -> erlang:halt(Code);
        SignalStatus -> erlang:halt(SignalStatus)
    end.

shared_random_hex(Bytes) ->
    'beamtrace_runtime@crypto':random_hex(Bytes).

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
