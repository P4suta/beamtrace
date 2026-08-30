%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_record_process_test_ffi).
-include_lib("kernel/include/file.hrl").

-export([
    demo_fixture_is_staged_in_the_private_gate/0,
    staged_launch_never_writes_a_crash_dump_to_cwd/0,
    gleam_javascript_target_rejected/0,
    mix_wrapper_runs/0,
    packaged_environment_isolated/0,
    rebar3_wrapper_runs/0,
    record_signal_cleanup/0,
    record_signal_fixture/0,
    temp_gate_contract/0,
    timeout_cleans_gate_and_reports_tail/0,
    wrapper_trigger_path_preloaded/0,
    stopped_child_process_exits/0
]).

-define(SIGNAL_TIMEOUT_MS, 10000).
-define(RECORD_COMMAND_TIMEOUT_MS, 30000).

gleam_javascript_target_rejected() ->
    case os:find_executable("gleam") of
        false -> {error, <<"gleam executable was not found">>};
        _ ->
            case beamtrace_cli_ffi:start_gated_command(
                [<<"gleam">>, <<"run">>, <<"--target">>, <<"javascript">>],
                <<"beamtrace_gleam_target_test@localhost">>,
                <<"beamtrace_gleam_target_cookie">>,
                <<"beamtrace_demo_fixture">>
            ) of
                {error, <<"record requires gleam run --target erlang">>} ->
                    {ok, nil};
                Other -> {error, unicode:characters_to_binary(
                    io_lib:format("unexpected Gleam target result: ~0p", [Other])
                )}
            end
    end.

demo_fixture_is_staged_in_the_private_gate() ->
    {ok, Command} = beamtrace_cli_ffi:demo_command(),
    {ok, Node} = beamtrace_cli_ffi:auto_record_node(),
    case beamtrace_cli_ffi:start_gated_command(
        Command,
        Node,
        <<"beamtrace_demo_stage_cookie">>,
        <<"beamtrace_demo_fixture">>,
        [<<"beamtrace_demo_fixture">>]
    ) of
        {ok, Handle = {gated_command, _Port, Directory, _Gate, _FinishGate,
                       _Guardian, _OsPid}} ->
            Beam = filename:join(
                binary_to_list(Directory), "beamtrace_demo_fixture.beam"
            ),
            Staged = filelib:is_regular(Beam),
            Private = private_file(Beam),
            {ok, nil} = beamtrace_cli_ffi:release_gated_command(Handle),
            {ok, nil} = beamtrace_cli_ffi:release_gated_command_finish(Handle),
            Result = beamtrace_cli_ffi:await_gated_command(
                Handle, ?RECORD_COMMAND_TIMEOUT_MS
            ),
            Clean = not filelib:is_dir(binary_to_list(Directory)),
            case {Staged, Private, Result, Clean} of
                {true, true, {ok, {0, Output}}, true} ->
                    case binary:match(
                        Output, <<"BeamTrace demo checkout total: 2500">>
                    ) of
                        nomatch -> {error, <<"demo output was missing">>};
                        _ -> {ok, nil}
                    end;
                Other -> {error, unicode:characters_to_binary(io_lib:format(
                    "demo staging contract failed: ~0p", [Other]
                ))}
            end;
        Error -> Error
    end.

staged_launch_never_writes_a_crash_dump_to_cwd() ->
    Root = wrapper_project_directory(crash),
    ok = file:make_dir(Root),
    {ok, OriginalDirectory} = file:get_cwd(),
    {ok, [Erl | _]} = beamtrace_cli_ffi:demo_command(),
    {ok, Node} = beamtrace_cli_ffi:auto_record_node(),
    try
        ok = file:set_cwd(Root),
        case beamtrace_cli_ffi:start_gated_command(
            [Erl, <<"-noshell">>, <<"-s">>, <<"beamtrace_missing_module">>,
             <<"run">>],
            Node,
            <<"beamtrace_crash_test_cookie">>,
            <<"beamtrace_missing_module">>,
            []
        ) of
            {ok, Handle = {gated_command, _Port, Directory, _Gate,
                           _FinishGate, _Guardian, _OsPid}} ->
                {ok, nil} = beamtrace_cli_ffi:release_gated_command(Handle),
                {ok, nil} =
                    beamtrace_cli_ffi:release_gated_command_finish(Handle),
                Result = beamtrace_cli_ffi:await_gated_command(
                    Handle, ?RECORD_COMMAND_TIMEOUT_MS
                ),
                ok = file:set_cwd(OriginalDirectory),
                Dump = filelib:is_regular(filename:join(Root, "erl_crash.dump")),
                Clean = not filelib:is_dir(binary_to_list(Directory)),
                case {Result, Dump, Clean} of
                    {{ok, {Status, Output}}, false, true} when Status =/= 0 ->
                        case binary:match(Output, <<"crash dump slogan:">>) of
                            nomatch -> {error, unicode:characters_to_binary(
                                io_lib:format("slogan missing: ~ts", [Output])
                            )};
                            _ -> {ok, nil}
                        end;
                    Other -> {error, unicode:characters_to_binary(
                        io_lib:format("crash dump contract failed: ~0p", [Other])
                    )}
                end;
            Error -> Error
        end
    after
        _ = file:set_cwd(OriginalDirectory),
        _ = file:del_dir_r(Root)
    end.

private_file(Path) ->
    case os:type() of
        {win32, _} -> true;
        _ ->
            case file:read_file_info(Path) of
                {ok, #file_info{mode = Mode}} -> Mode band 8#777 =:= 8#600;
                _ -> false
            end
    end.

rebar3_wrapper_runs() ->
    case os:find_executable("rebar3") of
        false -> {error, <<"rebar3 executable was not found">>};
        _ -> with_wrapper_project(rebar3)
    end.

mix_wrapper_runs() ->
    case os:find_executable("mix") of
        false -> mix_unavailable();
        _ ->
            case beamtrace_cli_ffi:run_command([<<"mix">>, <<"--version">>]) of
                {ok, {0, _Output}} -> with_wrapper_project(mix);
                _ -> mix_unavailable()
            end
    end.

mix_unavailable() ->
    case os:getenv("BEAMTRACE_REQUIRE_ELIXIR") of
        "1" -> {error, <<"mix was required but is not usable">>};
        _ -> {ok, <<"skipped">>}
    end.

with_wrapper_project(Tool) ->
    Directory = wrapper_project_directory(Tool),
    {ok, OriginalDirectory} = file:get_cwd(),
    try
        ok = create_wrapper_project(Directory, Tool),
        ok = file:set_cwd(Directory),
        StartResult = start_wrapper_command(Tool),
        ok = file:set_cwd(OriginalDirectory),
        finish_wrapper_command(StartResult, Tool)
    catch
        Class:Reason:Stacktrace ->
            {error, unicode:characters_to_binary(io_lib:format(
                "wrapper test ~p failed: ~0p:~0p ~0p",
                [Tool, Class, Reason, Stacktrace]
            ))}
    after
        _ = file:set_cwd(OriginalDirectory),
        _ = file:del_dir_r(Directory)
    end.

wrapper_project_directory(Tool) ->
    Root = first_environment_directory([
        "TMPDIR", "TEMP", "TMP"
    ]),
    filename:join(Root, lists:flatten(io_lib:format(
        "beamtrace-record-~p-wrapper-~B",
        [Tool, erlang:unique_integer([positive, monotonic])]
    ))).

first_environment_directory([Name | Rest]) ->
    case os:getenv(Name) of
        false -> first_environment_directory(Rest);
        [] -> first_environment_directory(Rest);
        Value -> filename:absname(Value)
    end;
first_environment_directory([]) ->
    case os:type() of
        {win32, _} -> filename:absname(".");
        _ -> "/tmp"
    end.

create_wrapper_project(Directory, rebar3) ->
    SourceDirectory = filename:join(Directory, "src"),
    ok = filelib:ensure_dir(filename:join(SourceDirectory, ".keep")),
    ok = file:write_file(
        filename:join(Directory, "rebar.config"),
        <<"{erl_opts, [debug_info, warnings_as_errors]}.\n">>
    ),
    ok = file:write_file(
        filename:join(SourceDirectory, "beamtrace_record_rebar_fixture.app.src"),
        <<"{application, beamtrace_record_rebar_fixture,\n"
          " [{description, \"BeamTrace record fixture\"},\n"
          "  {vsn, \"0.1.0\"}, {modules, []}, {registered, []},\n"
          "  {applications, [kernel, stdlib]}]}.\n">>
    ),
    file:write_file(
        filename:join(SourceDirectory, "beamtrace_record_rebar_target.erl"),
        <<"-module(beamtrace_record_rebar_target).\n"
          "-export([run/0]).\n"
          "run() -> io:format(\"rebar-wrapper-ran~n\"), ok.\n">>
    );
create_wrapper_project(Directory, mix) ->
    SourceDirectory = filename:join(Directory, "lib"),
    ok = filelib:ensure_dir(filename:join(SourceDirectory, ".keep")),
    ok = file:write_file(
        filename:join(Directory, "mix.exs"),
        <<"defmodule BeamtraceRecordMixFixture.MixProject do\n"
          "  use Mix.Project\n"
          "  def project, do: [app: :beamtrace_record_mix_fixture, "
          "version: \"0.1.0\", elixir: \"~> 1.17\"]\n"
          "  def application, do: [extra_applications: [:logger]]\n"
          "end\n">>
    ),
    file:write_file(
        filename:join(SourceDirectory, "beamtrace_record_mix_target.ex"),
        <<"defmodule BeamtraceRecordMixTarget do\n"
          "  def run, do: IO.write(\"mix-wrapper-ran\\n\")\n"
          "end\n">>
    ).

start_wrapper_command(rebar3) ->
    {ok, Node} = beamtrace_cli_ffi:auto_record_node(),
    beamtrace_cli_ffi:start_gated_command(
        [
            <<"rebar3">>, <<"shell">>, <<"--eval">>,
            <<"beamtrace_record_rebar_target:run(), init:stop().">>
        ],
        Node,
        <<"beamtrace_rebar_wrapper_cookie">>,
        <<"beamtrace_record_rebar_target">>
    );
start_wrapper_command(mix) ->
    {ok, Node} = beamtrace_cli_ffi:auto_record_node(),
    beamtrace_cli_ffi:start_gated_command(
        [
            <<"mix">>, <<"run">>, <<"-e">>,
            <<"BeamtraceRecordMixTarget.run(); :init.stop()">>
        ],
        Node,
        <<"beamtrace_mix_wrapper_cookie">>,
        <<"Elixir.BeamtraceRecordMixTarget">>
    ).

finish_wrapper_command({ok, Handle}, Tool) ->
    case beamtrace_cli_ffi:release_gated_command(Handle) of
        {error, Reason} ->
            nil = beamtrace_cli_ffi:stop_gated_command(Handle),
            {error, Reason};
        {ok, nil} ->
            case beamtrace_cli_ffi:release_gated_command_finish(Handle) of
                {error, Reason} ->
                    nil = beamtrace_cli_ffi:stop_gated_command(Handle),
                    {error, Reason};
                {ok, nil} -> wrapper_output(
                    beamtrace_cli_ffi:await_gated_command(Handle, 60000), Tool
                )
            end
    end;
finish_wrapper_command(Error, _Tool) -> Error.

wrapper_output({ok, {0, Output}}, rebar3) ->
    case binary:match(Output, <<"rebar-wrapper-ran">>) of
        nomatch -> {error, <<"Rebar3 wrapper output was missing">>};
        _ -> {ok, <<"rebar-wrapper-ran">>}
    end;
wrapper_output({ok, {0, Output}}, mix) ->
    case binary:match(Output, <<"mix-wrapper-ran">>) of
        nomatch -> {error, <<"Mix wrapper output was missing">>};
        _ -> {ok, <<"mix-wrapper-ran">>}
    end;
wrapper_output({ok, {Status, Output}}, Tool) ->
    {error, unicode:characters_to_binary(io_lib:format(
        "~p wrapper exited with status ~B: ~ts", [Tool, Status, Output]
    ))};
wrapper_output({error, Reason}, _Tool) -> {error, Reason}.

stopped_child_process_exits() ->
    case os:type() of
        {win32, _} -> {ok, nil};
        {unix, _} -> stopped_unix_child_process_exits()
    end.

timeout_cleans_gate_and_reports_tail() ->
    Unique = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Node = <<"beamtrace_timeout_test_", Unique/binary, "@localhost">>,
    ReadyPath = filename:join(
        first_environment_directory(["TMPDIR", "TEMP", "TMP"]),
        "beamtrace-record-timeout-ready-" ++ binary_to_list(Unique)
    ),
    ReadyBinary = unicode:characters_to_binary(ReadyPath),
    Expression = unicode:characters_to_binary(io_lib:format(
        "io:format(\"record-timeout-tail~n\"), "
        "ok = file:write_file(~0p, <<\"ready\">>), "
        "receive beamtrace_never -> ok end.",
        [ReadyBinary]
    )),
    try
        case beamtrace_cli_ffi:start_gated_command(
            [<<"erl">>, <<"-noshell">>, <<"-eval">>, Expression],
            Node,
            <<"beamtrace_timeout_test_cookie">>,
            <<"erlang">>
        ) of
            {ok, Handle = {gated_command, _Port, Directory, _Gate, _FinishGate,
                           _Guardian, OsPid}} ->
                {ok, nil} = beamtrace_cli_ffi:release_gated_command(Handle),
                Ready = wait_for_regular_file(ReadyPath, 500),
                Result = case Ready of
                    true -> beamtrace_cli_ffi:await_gated_command(Handle, 250);
                    false ->
                        nil = beamtrace_cli_ffi:stop_gated_command(Handle),
                        {error, <<"record child did not reach its output marker">>}
                end,
                Clean = not filelib:is_dir(binary_to_list(Directory)),
                Exited = case OsPid of
                    Pid when is_integer(Pid) -> wait_for_process_exit(Pid, 100);
                    _ -> true
                end,
                case Result of
                    {error, Reason} ->
                        TimedOut = binary:match(
                            Reason, <<"record command timed out">>
                        ) =/= nomatch,
                        Tail = binary:match(
                            Reason, <<"record-timeout-tail">>
                        ) =/= nomatch,
                        case Ready andalso TimedOut andalso Tail
                                andalso Clean andalso Exited of
                            true -> {ok, nil};
                            false -> {error, unicode:characters_to_binary(
                                io_lib:format(
                                    "record timeout contract failed: ready=~p reason=~ts clean=~p exited=~p",
                                    [Ready, Reason, Clean, Exited]
                                )
                            )}
                        end;
                    Other -> {error, unicode:characters_to_binary(
                        io_lib:format(
                            "record timeout unexpectedly completed: ~0p", [Other]
                        )
                    )}
                end;
            Error -> Error
        end
    after
        _ = file:delete(ReadyPath)
    end.

record_signal_cleanup() ->
    case os:type() of
        {win32, _} -> {ok, nil};
        {unix, _} -> run_record_signal_cleanup()
    end.

run_record_signal_cleanup() ->
    Root = wrapper_project_directory(signal),
    ok = file:make_dir(Root),
    ok = file:change_mode(Root, 8#700),
    case os:find_executable("erl") of
        false ->
            _ = file:del_dir(Root),
            {error, <<"erl executable was not found">>};
        Erl ->
            Paths = lists:usort([
                filename:absname(Path)
                || Path <- code:get_path(), filelib:is_dir(Path)
            ]),
            PathArguments = lists:append([["-pa", Path] || Path <- Paths]),
            Port = open_port(
                {spawn_executable, Erl},
                [binary, exit_status, stderr_to_stdout, use_stdio,
                 {env, [{"TMPDIR", Root}]},
                 {args, PathArguments ++ [
                    "-noshell", "-s", atom_to_list(?MODULE),
                    "record_signal_fixture"
                 ]}]
            ),
            {os_pid, BeamPid} = erlang:port_info(Port, os_pid),
            try
                Deadline = erlang:monotonic_time(millisecond)
                    + ?SIGNAL_TIMEOUT_MS,
                case await_record_signal_ready(Port, <<>>, Deadline) of
                    {error, Reason} -> {error, Reason};
                    {ok, ChildPid, Output} -> finish_record_signal_cleanup(
                        Port, BeamPid, ChildPid, Root, Output, Deadline
                    )
                end
            after
                case erlang:port_info(Port) of
                    undefined -> ok;
                    _ ->
                        _ = send_record_signal(BeamPid),
                        try port_close(Port) catch _:_ -> ok end
                end,
                _ = file:del_dir_r(Root)
            end
    end.

record_signal_fixture() ->
    {ok, Node} = beamtrace_cli_ffi:auto_record_node(),
    case beamtrace_cli_ffi:start_gated_command(
        [<<"erl">>, <<"-noshell">>, <<"-eval">>,
         <<"receive beamtrace_never -> ok end.">>],
        Node,
        <<"beamtrace_signal_test_cookie">>,
        <<"erlang">>
    ) of
        {ok, Handle = {gated_command, Port, _Directory, _Gate, _FinishGate,
                      _Guardian, ChildPid}} when is_integer(ChildPid) ->
            io:format("BEAMTRACE_RECORD_SIGNAL_READY=~B~n", [ChildPid]),
            record_signal_owner_race(Port, Handle);
        Other ->
            io:format(
                standard_error,
                "record signal fixture failed to start: ~0p~n",
                [Other]
            ),
            erlang:halt(2)
    end.

record_signal_owner_race(Port, Handle) ->
    receive
        {Port, {data, _Data}} -> record_signal_owner_race(Port, Handle);
        {Port, {exit_status, _Status}} ->
            SignalStatus = beamtrace_cli_ffi:record_shutdown_exit_code(),
            nil = beamtrace_cli_ffi:stop_gated_command(Handle),
            %% The guardian must publish 143 before terminating the child. If
            %% the owner can observe the exit first, it could replace the
            %% requested status during normal CLI cleanup.
            case SignalStatus of
                143 -> erlang:halt(143);
                _ -> erlang:halt(2)
            end
    end.

await_record_signal_ready(Port, Output, Deadline) ->
    case re:run(
        Output,
        <<"BEAMTRACE_RECORD_SIGNAL_READY=([0-9]+)">>,
        [{capture, [1], binary}]
    ) of
        {match, [ChildPid]} ->
            {ok, binary_to_integer(ChildPid), Output};
        nomatch ->
            Remaining = erlang:max(
                0, Deadline - erlang:monotonic_time(millisecond)
            ),
            receive
                {Port, {data, Data}} ->
                    await_record_signal_ready(
                        Port, append_test_tail(Output, Data), Deadline
                    );
                {Port, {exit_status, Status}} ->
                    {error, unicode:characters_to_binary(io_lib:format(
                        "record signal fixture exited with status ~B: ~ts",
                        [Status, Output]
                    ))}
            after Remaining ->
                {error, unicode:characters_to_binary(io_lib:format(
                    "record signal fixture readiness timed out: ~ts",
                    [Output]
                ))}
            end
    end.

finish_record_signal_cleanup(
        Port, BeamPid, ChildPid, Root, Output, Deadline
    ) ->
    case send_record_signal(BeamPid) of
        {error, Reason} -> {error, Reason};
        {ok, nil} ->
            case collect_record_signal_exit(Port, Output, Deadline) of
                {ok, {143, _FinalOutput}} ->
                    case {
                        wait_for_process_exit(ChildPid, 100),
                        file:list_dir(Root)
                    } of
                        {true, {ok, []}} -> {ok, nil};
                        {false, _} ->
                            {error, <<"record child survived parent SIGTERM">>};
                        {_, {ok, Remaining}} ->
                            {error, unicode:characters_to_binary(io_lib:format(
                                "record temp entries survived SIGTERM: ~0p",
                                [Remaining]
                            ))};
                        {_, {error, ListReason}} ->
                            {error, unicode:characters_to_binary(io_lib:format(
                                "record signal temp inspection failed: ~0p",
                                [ListReason]
                            ))}
                    end;
                {ok, {Status, FinalOutput}} ->
                    {error, unicode:characters_to_binary(io_lib:format(
                        "record signal fixture exited with status ~B: ~ts",
                        [Status, FinalOutput]
                    ))};
                {error, Reason} -> {error, Reason}
            end
    end.

send_record_signal(Pid) ->
    case beamtrace_cli_ffi:run_command([
        <<"kill">>, <<"-TERM">>, integer_to_binary(Pid)
    ]) of
        {ok, {0, _Output}} -> {ok, nil};
        {ok, {Status, Output}} ->
            {error, unicode:characters_to_binary(io_lib:format(
                "kill exited with status ~B: ~ts", [Status, Output]
            ))};
        {error, Reason} -> {error, Reason}
    end.

collect_record_signal_exit(Port, Output, Deadline) ->
    Remaining = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)
    ),
    receive
        {Port, {data, Data}} -> collect_record_signal_exit(
            Port, append_test_tail(Output, Data), Deadline
        );
        {Port, {exit_status, Status}} -> {ok, {Status, Output}}
    after Remaining ->
        {error, unicode:characters_to_binary(io_lib:format(
            "record signal shutdown timed out: ~ts", [Output]
        ))}
    end.

append_test_tail(Existing, New) ->
    Combined = <<Existing/binary, New/binary>>,
    case byte_size(Combined) > 65536 of
        true -> binary:part(Combined, byte_size(Combined) - 65536, 65536);
        false -> Combined
    end.

wait_for_regular_file(_Path, 0) -> false;
wait_for_regular_file(Path, Attempts) ->
    case filelib:is_regular(Path) of
        true -> true;
        false ->
            timer:sleep(20),
            wait_for_regular_file(Path, Attempts - 1)
    end.

stopped_unix_child_process_exits() ->
    Unique = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Node = <<"beamtrace_stop_test_", Unique/binary, "@localhost">>,
    case beamtrace_cli_ffi:start_gated_command(
        [<<"erl">>, <<"-noshell">>],
        Node,
        <<"beamtrace_stop_test_cookie">>,
        <<"erlang">>
    ) of
        {ok, Handle = {gated_command, _Port, _Directory, _Gate, _FinishGate,
                       _Guardian, OsPid}} when is_integer(OsPid) ->
            Running = os_process_exists(OsPid),
            nil = beamtrace_cli_ffi:stop_gated_command(Handle),
            case Running andalso wait_for_process_exit(OsPid, 100) of
                true -> {ok, nil};
                false -> {error, <<"gated child OS process was not terminated">>}
            end;
        {ok, Handle} ->
            nil = beamtrace_cli_ffi:stop_gated_command(Handle),
            {error, <<"gated child OS pid was unavailable">>};
        Error -> Error
    end.

wait_for_process_exit(_Pid, 0) -> false;
wait_for_process_exit(Pid, Attempts) ->
    case os_process_exists(Pid) of
        false -> true;
        true ->
            timer:sleep(20),
            wait_for_process_exit(Pid, Attempts - 1)
    end.

os_process_exists(Pid) ->
    case beamtrace_cli_ffi:run_command([
        <<"kill">>, <<"-0">>, integer_to_binary(Pid)
    ]) of
        {ok, {0, _}} -> true;
        _ -> false
    end.

wrapper_trigger_path_preloaded() ->
    Command = [
        <<"erl">>,
        <<"-noshell">>,
        <<"-eval">>,
        <<"beamtrace_demo_fixture:run().">>
    ],
    case beamtrace_cli_ffi:start_gated_command(
        Command,
        <<"beamtrace_wrapper_path_test@localhost">>,
        <<"beamtrace_wrapper_path_cookie">>,
        <<"beamtrace_demo_fixture">>
    ) of
        {ok, Handle} ->
            {ok, nil} = beamtrace_cli_ffi:release_gated_command(Handle),
            {ok, nil} = beamtrace_cli_ffi:release_gated_command_finish(Handle),
            case beamtrace_cli_ffi:await_gated_command(
                Handle, ?RECORD_COMMAND_TIMEOUT_MS
            ) of
                {ok, {0, Output}} -> {ok, Output};
                Other ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("~0p", [Other])
                    )}
            end;
        Error -> Error
    end.

temp_gate_contract() ->
    Saved = os:getenv("TMPDIR"),
    Root = filename:absname(filename:join(
        "build",
        "beamtrace-record-temp-" ++ integer_to_list(
            erlang:unique_integer([positive, monotonic])
        )
    )),
    try
        ok = filelib:ensure_dir(filename:join(Root, ".keep")),
        true = os:putenv("TMPDIR", Root),
        check_temp_gate(Root)
    after
        restore("TMPDIR", Saved),
        _ = file:del_dir(Root)
    end.

check_temp_gate(Root) ->
    case beamtrace_cli_ffi:start_gated_command(
        [<<"git">>, <<"cat-file">>, <<"--batch">>],
        <<"beamtrace_temp_test@localhost">>,
        <<"beamtrace_temp_cookie">>
    ) of
        {ok, Handle = {gated_command, _Port, DirectoryBinary, GateBinary,
                       FinishGateBinary, _Guardian, _OsPid}} ->
            Directory = binary_to_list(DirectoryBinary),
            Gate = binary_to_list(GateBinary),
            FinishGate = binary_to_list(FinishGateBinary),
            Guard = filename:join(Directory, "guard.beam"),
            Before = filename:dirname(Directory) =:= Root
                andalso secure_mode(Directory, 8#700)
                andalso filelib:is_regular(Guard)
                andalso secure_mode(Guard, 8#600)
                andalso not filelib:is_file(Gate)
                andalso not filelib:is_file(FinishGate),
            {ok, nil} = beamtrace_cli_ffi:release_gated_command(Handle),
            Marker = filelib:is_file(Gate) andalso secure_mode(Gate, 8#600),
            {ok, nil} = beamtrace_cli_ffi:release_gated_command_finish(Handle),
            FinishMarker = filelib:is_file(FinishGate)
                andalso secure_mode(FinishGate, 8#600),
            nil = beamtrace_cli_ffi:stop_gated_command(Handle),
            Clean = not filelib:is_dir(Directory)
                andalso not filelib:is_file(Gate)
                andalso not filelib:is_file(FinishGate)
                andalso not filelib:is_file(Guard),
            case Before andalso Marker andalso FinishMarker andalso Clean of
                true -> {ok, nil};
                false -> {error, unicode:characters_to_binary(io_lib:format(
                    "record temp gate contract failed: before=~p marker=~p finish=~p clean=~p root=~ts directory=~ts",
                    [Before, Marker, FinishMarker, Clean, Root, Directory]
                ))}
            end;
        Error -> Error
    end.

secure_mode(Path, Expected) ->
    case os:type() of
        {win32, _} -> true;
        _ ->
            case file:read_file_info(Path) of
                {ok, #file_info{mode = Mode}} -> Mode band 8#777 =:= Expected;
                _ -> false
            end
    end.

packaged_environment_isolated() ->
    Names = [
        "PATH",
        "ERL_ROOTDIR",
        "ROOTDIR",
        "ERL_LIBS",
        "BINDIR",
        "EMU",
        "PROGNAME",
        "ESCRIPT_NAME",
        "BEAMTRACE_AGENT_BEAM",
        "BEAMTRACE_WEB_ROOT",
        "BEAMTRACE_BUNDLED_RUNTIME",
        "BEAMTRACE_PARENT_ERL_ROOTDIR_SET",
        "BEAMTRACE_PARENT_ERL_ROOTDIR",
        "BEAMTRACE_PARENT_ROOTDIR_SET",
        "BEAMTRACE_PARENT_ROOTDIR",
        "BEAMTRACE_PARENT_ERL_LIBS_SET",
        "BEAMTRACE_PARENT_ERL_LIBS",
        "BEAMTRACE_PARENT_PATH_SET",
        "BEAMTRACE_PARENT_PATH",
        "BEAMTRACE_PARENT_BINDIR_SET",
        "BEAMTRACE_PARENT_BINDIR",
        "BEAMTRACE_PARENT_EMU_SET",
        "BEAMTRACE_PARENT_EMU",
        "BEAMTRACE_PARENT_PROGNAME_SET",
        "BEAMTRACE_PARENT_PROGNAME",
        "BEAMTRACE_PARENT_ESCRIPT_NAME_SET",
        "BEAMTRACE_PARENT_ESCRIPT_NAME"
    ],
    Saved = [{Name, os:getenv(Name)} || Name <- Names],
    try
        ParentPath = required_test_environment("PATH"),
        true = os:putenv("PATH", "/beamtrace-invalid-runtime/bin:" ++ ParentPath),
        true = os:putenv("ERL_ROOTDIR", "/beamtrace-invalid-runtime"),
        true = os:putenv("ROOTDIR", "/beamtrace-invalid-runtime"),
        true = os:putenv("ERL_LIBS", "/beamtrace-invalid-libs"),
        true = os:putenv("BINDIR", "/beamtrace-invalid-runtime/bin"),
        true = os:putenv("EMU", "beamtrace-invalid-emu"),
        true = os:putenv("PROGNAME", "beamtrace-invalid-progname"),
        true = os:putenv("ESCRIPT_NAME", "/beamtrace-invalid.escript"),
        true = os:putenv("BEAMTRACE_AGENT_BEAM", "/beamtrace-invalid-agent"),
        true = os:putenv("BEAMTRACE_WEB_ROOT", "/beamtrace-invalid-web"),
        true = os:putenv("BEAMTRACE_BUNDLED_RUNTIME", "1"),
        true = os:putenv("BEAMTRACE_PARENT_ERL_ROOTDIR_SET", "0"),
        true = os:putenv("BEAMTRACE_PARENT_ROOTDIR_SET", "0"),
        true = os:putenv("BEAMTRACE_PARENT_ERL_LIBS_SET", "0"),
        true = os:putenv("BEAMTRACE_PARENT_PATH_SET", "1"),
        true = os:putenv("BEAMTRACE_PARENT_PATH", ParentPath),
        true = os:putenv("BEAMTRACE_PARENT_BINDIR_SET", "0"),
        true = os:putenv("BEAMTRACE_PARENT_EMU_SET", "0"),
        true = os:putenv("BEAMTRACE_PARENT_PROGNAME_SET", "0"),
        true = os:putenv("BEAMTRACE_PARENT_ESCRIPT_NAME_SET", "0"),
        run_child()
    after
        [restore(Name, Value) || {Name, Value} <- Saved]
    end.

run_child() ->
    Expression = iolist_to_binary([
        "io:format(\"~p\", [",
        "string:str(os:getenv(\"PATH\"), \"/beamtrace-invalid-runtime\") =:= 0 andalso ",
        "os:getenv(\"ERL_ROOTDIR\") =/= \"/beamtrace-invalid-runtime\" andalso ",
        "os:getenv(\"ROOTDIR\") =/= \"/beamtrace-invalid-runtime\" andalso ",
        "os:getenv(\"ERL_LIBS\") =/= \"/beamtrace-invalid-libs\" andalso ",
        "os:getenv(\"BINDIR\") =/= \"/beamtrace-invalid-runtime/bin\" andalso ",
        "os:getenv(\"EMU\") =/= \"beamtrace-invalid-emu\" andalso ",
        "os:getenv(\"PROGNAME\") =/= \"beamtrace-invalid-progname\" andalso ",
        "os:getenv(\"ESCRIPT_NAME\") =/= \"/beamtrace-invalid.escript\" andalso ",
        "os:getenv(\"BEAMTRACE_AGENT_BEAM\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_WEB_ROOT\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_BUNDLED_RUNTIME\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_ERL_ROOTDIR_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_ROOTDIR_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_ERL_LIBS_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_PATH_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_BINDIR_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_EMU_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_PROGNAME_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_ESCRIPT_NAME_SET\") =:= false])."
    ]),
    Command = [
        <<"erl">>,
        <<"-noshell">>,
        <<"-eval">>,
        Expression,
        <<"-s">>,
        <<"init">>,
        <<"stop">>
    ],
    case beamtrace_cli_ffi:start_gated_command(
        Command,
        <<"beamtrace_env_test@localhost">>,
        <<"beamtrace_env_cookie">>
    ) of
        {ok, Handle} ->
            {ok, nil} = beamtrace_cli_ffi:release_gated_command(Handle),
            {ok, nil} = beamtrace_cli_ffi:release_gated_command_finish(Handle),
            case beamtrace_cli_ffi:await_gated_command(
                Handle, ?RECORD_COMMAND_TIMEOUT_MS
            ) of
                {ok, {0, Output}} -> {ok, Output};
                Other ->
                    {error, unicode:characters_to_binary(io_lib:format("~0p", [Other]))}
            end;
        Error -> Error
    end.

restore(Name, false) -> os:unsetenv(Name);
restore(Name, Value) -> os:putenv(Name, Value).

required_test_environment(Name) ->
    case os:getenv(Name) of
        false -> erlang:error({missing_test_environment, Name});
        Value -> Value
    end.
