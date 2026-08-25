%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_server_test_ffi).

-export([server_signal_lifecycle/0, with_occupied_loopback_port/1]).

-define(SIGNAL_TIMEOUT_MS, 10000).

server_signal_lifecycle() ->
    case os:type() of
        {win32, _} -> {ok, nil};
        {unix, _} -> run_signal_case(sigterm)
    end.

run_signal_case(Signal) ->
    case os:find_executable("erl") of
        false -> {error, <<"erl executable was not found">>};
        Erl ->
            Paths = lists:usort([
                filename:absname(Path)
                || Path <- code:get_path(), filelib:is_dir(Path)
            ]),
            PathArguments = lists:append([
                ["-pa", Path] || Path <- Paths
            ]),
            Expression =
                "io:format(\"BEAMTRACE_TEST_OS_PID=~s~n\", [os:getpid()]), "
                "Result = 'beamtrace_runtime@server':start("
                "<<\"127.0.0.1\">>, 0, local, "
                "<<\"beamtrace-signal-lifecycle-test\">>, none, none), "
                "case Result of {ok, nil} -> erlang:halt(0); "
                "Error -> io:format(standard_error, \"server error: ~0p~n\", "
                "[Error]), erlang:halt(2) end.",
            Port = open_port(
                {spawn_executable, Erl},
                [binary, exit_status, stderr_to_stdout, use_stdio,
                 {args, PathArguments ++ ["-noshell", "-eval", Expression]}]
            ),
            {os_pid, OsPid} = erlang:port_info(Port, os_pid),
            try run_started_signal_case(Port, OsPid, Signal)
            after
                case erlang:port_info(Port) of
                    undefined -> ok;
                    _ ->
                        _ = send_signal(OsPid, sigterm),
                        try port_close(Port) catch _:_ -> ok end
                end
            end
    end.

run_started_signal_case(Port, _LauncherOsPid, Signal) ->
    Deadline = erlang:monotonic_time(millisecond) + ?SIGNAL_TIMEOUT_MS,
    case await_ready(Port, <<>>, Deadline) of
        {error, Reason} -> {error, Reason};
        {ok, HttpPort, BeamOsPid, Output} ->
            case {http_ok(HttpPort, <<"/api/v1/health">>),
                  http_ok(HttpPort, <<"/api/v1/ready">>)} of
                {true, true} -> finish_signal_case(
                    Port, BeamOsPid, Signal, Output, Deadline
                );
                _ -> {error, <<"server health or readiness probe failed">>}
            end
    end.

finish_signal_case(Port, OsPid, Signal, Output, Deadline) ->
    case send_signal(OsPid, Signal) of
        {error, Reason} -> {error, Reason};
        {ok, nil} ->
            case collect_exit(Port, Output, Deadline) of
                {ok, {0, FinalOutput}} ->
                    case {binary:match(FinalOutput, <<"server.ready">>),
                          binary:match(FinalOutput, <<"server.closed">>)} of
                        {nomatch, _} ->
                            {error, <<"server ready log was missing">>};
                        {_, nomatch} ->
                            {error, <<"server close log was missing">>};
                        _ -> {ok, nil}
                    end;
                {ok, {Status, FinalOutput}} ->
                    {error, unicode:characters_to_binary(io_lib:format(
                        "server signal ~p exited with status ~B: ~ts",
                        [Signal, Status, FinalOutput]
                    ))};
                {error, Reason} ->
                    {error, unicode:characters_to_binary(io_lib:format(
                        "server signal ~p failed: ~ts",
                        [Signal, Reason]
                    ))}
            end
    end.

await_ready(Port, Output, Deadline) ->
    case ready_process(Output) of
        {ok, HttpPort, BeamOsPid} -> {ok, HttpPort, BeamOsPid, Output};
        error ->
            Remaining = erlang:max(
                0, Deadline - erlang:monotonic_time(millisecond)
            ),
            receive
                {Port, {data, Data}} ->
                    await_ready(Port, append_tail(Output, Data), Deadline);
                {Port, {exit_status, Status}} ->
                    {error, unicode:characters_to_binary(io_lib:format(
                        "server exited before readiness with status ~B: ~ts",
                        [Status, Output]
                    ))}
            after Remaining ->
                {error, <<"server readiness timed out">>}
            end
    end.

ready_process(Output) ->
    case {
        re:run(
            Output,
            <<"BeamTrace workspace: http://127\\.0\\.0\\.1:([0-9]+)">>,
            [{capture, [1], binary}]
        ),
        re:run(
            Output,
            <<"BEAMTRACE_TEST_OS_PID=([0-9]+)">>,
            [{capture, [1], binary}]
        )
    } of
        {{match, [Port]}, {match, [OsPid]}} ->
            {ok, binary_to_integer(Port), binary_to_integer(OsPid)};
        _ -> error
    end.

http_ok(Port, Path) ->
    case gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}], 2000
    ) of
        {error, _} -> false;
        {ok, Socket} ->
            Request = <<"GET ", Path/binary, " HTTP/1.1\r\n"
                        "Host: 127.0.0.1\r\nConnection: close\r\n\r\n">>,
            Result = case gen_tcp:send(Socket, Request) of
                ok -> recv_http(Socket, <<>>);
                {error, _} -> <<>>
            end,
            ok = gen_tcp:close(Socket),
            binary:match(Result, <<" 200 ">>) =/= nomatch
    end.

recv_http(Socket, Accumulator) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {ok, Data} -> recv_http(Socket, append_tail(Accumulator, Data));
        {error, closed} -> Accumulator;
        {error, _} -> Accumulator
    end.

send_signal(OsPid, Signal) ->
    case os:find_executable("kill") of
        false -> {error, <<"kill executable was not found">>};
        Kill ->
            Name = case Signal of
                sigint -> "-INT";
                sigterm -> "-TERM"
            end,
            SignalPort = open_port(
                {spawn_executable, Kill},
                [binary, exit_status, stderr_to_stdout, use_stdio,
                 {args, [Name, integer_to_list(OsPid)]}]
            ),
            collect_signal_command(SignalPort, <<>>)
    end.

collect_signal_command(Port, Output) ->
    receive
        {Port, {data, Data}} ->
            collect_signal_command(Port, append_tail(Output, Data));
        {Port, {exit_status, 0}} -> {ok, nil};
        {Port, {exit_status, Status}} ->
            {error, unicode:characters_to_binary(io_lib:format(
                "kill exited with status ~B: ~ts", [Status, Output]
            ))}
    after 2000 ->
        {error, <<"kill command timed out">>}
    end.

collect_exit(Port, Output, Deadline) ->
    Remaining = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)
    ),
    receive
        {Port, {data, Data}} ->
            collect_exit(Port, append_tail(Output, Data), Deadline);
        {Port, {exit_status, Status}} -> {ok, {Status, Output}}
    after Remaining ->
        {error, unicode:characters_to_binary(io_lib:format(
            "server signal shutdown timed out; output: ~ts", [Output]
        ))}
    end.

append_tail(Existing, New) ->
    Combined = <<Existing/binary, New/binary>>,
    case byte_size(Combined) > 65536 of
        true -> binary:part(Combined, byte_size(Combined) - 65536, 65536);
        false -> Combined
    end.

with_occupied_loopback_port(Run) when is_function(Run, 1) ->
    {ok, Socket} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {ip, {127, 0, 0, 1}},
        {reuseaddr, false}
    ]),
    {ok, {_Address, Port}} = inet:sockname(Socket),
    try Run(Port)
    after
        ok = gen_tcp:close(Socket)
    end.
