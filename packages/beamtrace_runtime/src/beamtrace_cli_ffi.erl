%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_cli_ffi).

-export([
    read_cookie_file/1,
    read_cookie_default/0,
    read_record_cookie/0,
    write_text/2,
    random_secret/0,
    capture_id/0,
    web_root/0,
    doctor/0,
    run_command/1,
    start_gated_command/3,
    release_gated_command/1,
    release_gated_command_finish/1,
    await_gated_command/2,
    stop_gated_command/1,
    gated_command_running/1,
    halt/1
]).

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
        false -> {ok, binary:part(hex(crypto:strong_rand_bytes(32)), 0, 48)};
        Value -> normalize_secret(unicode:characters_to_binary(Value))
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
    base64:encode(crypto:strong_rand_bytes(48)).

capture_id() ->
    Random = binary:part(hex(crypto:strong_rand_bytes(16)), 0, 24),
    <<"capture-", Random/binary>>.

doctor() ->
    _ = [code:ensure_loaded(Module) || Module <- [trace, seq_trace, zip, crypto]],
    Otp = erlang:system_info(otp_release),
    WordSize = erlang:system_info(wordsize),
    TraceSession = erlang:function_exported(trace, session_create, 3),
    TraceSystem = erlang:function_exported(trace, system, 3),
    SeqTrace = erlang:function_exported(seq_trace, set_system_tracer, 1),
    Zip = erlang:function_exported(zip, create, 3),
    Crypto = erlang:function_exported(crypto, hash, 2),
    AgentBeam = case beamtrace_relay:agent_binary() of
        {ok, _Beam, _Filename, _Digest} -> "valid";
        {error, Reason} -> io_lib:format("unavailable (~0p)", [Reason])
    end,
    WebAssets = case valid_web_assets() of
        true -> "valid";
        false -> "unavailable"
    end,
    unicode:characters_to_binary(io_lib:format(
        "BeamTrace doctor~n"
        "  OTP release: ~s~n"
        "  word size: ~B bytes~n"
        "  isolated trace session: ~p~n"
        "  trace:system/3: ~p (OTP 27 uses system_monitor fallback)~n"
        "  seq_trace system tracer: ~p~n"
        "  ZIP storage: ~p~n"
        "  crypto: ~p~n"
        "  agent BEAM: ~s~n"
        "  web assets: ~s~n",
        [Otp, WordSize, TraceSession, TraceSystem, SeqTrace, Zip, Crypto, AgentBeam, WebAssets]
    )).

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
            collect_port(Port, [])
    end;
run_command([]) ->
    {error, <<"record command is empty">>}.

start_gated_command([Program | Arguments], Node, Cookie)
        when is_binary(Node), is_binary(Cookie) ->
    DirectErl = direct_erl_program(Program),
    case {command_executable(Program), record_flags(Node, Cookie, not DirectErl)} of
        {{ok, Executable}, {ok, Flags}} ->
            Gate = gate_path(),
            FinishGate = gate_path(),
            _ = file:delete(Gate),
            _ = file:delete(FinishGate),
            GatedArguments = case DirectErl of
                true -> insert_gate_arguments(Arguments);
                false -> Arguments
            end,
            Existing = case os:getenv("ERL_AFLAGS") of
                false -> "";
                Value -> Value
            end,
            CombinedFlags = string:trim(Flags ++ " " ++ Existing),
            try
                Port = open_port(
                    {spawn_executable, Executable},
                    [
                        binary,
                        exit_status,
                        stderr_to_stdout,
                        use_stdio,
                        {args, [binary_to_list(Arg) || Arg <- GatedArguments]},
                        {env, record_child_environment([
                            {"ERL_AFLAGS", CombinedFlags},
                            {"BEAMTRACE_RECORD_GATE", Gate},
                            {"BEAMTRACE_RECORD_FINISH_GATE", FinishGate}
                        ])}
                    ]
                ),
                {ok, {gated_command, Port,
                    unicode:characters_to_binary(Gate),
                    unicode:characters_to_binary(FinishGate),
                    DirectErl}}
            catch
                Class:Reason ->
                    {error, reason_binary({child_start_failed, Class, Reason})}
            end;
        {{error, Reason}, _} -> {error, Reason};
        {_, {error, Reason}} -> {error, Reason}
    end;
start_gated_command([], _Node, _Cookie) ->
    {error, <<"record command is empty">>};
start_gated_command(_Command, _Node, _Cookie) ->
    {error, <<"invalid gated command">>}.

record_child_environment(Base) ->
    case os:getenv("BEAMTRACE_BUNDLED_RUNTIME") of
        "1" ->
            Base ++ [
                restored_parent_environment(
                    "ERL_ROOTDIR",
                    "BEAMTRACE_PARENT_ERL_ROOTDIR_SET",
                    "BEAMTRACE_PARENT_ERL_ROOTDIR"
                ),
                restored_parent_environment(
                    "ROOTDIR",
                    "BEAMTRACE_PARENT_ROOTDIR_SET",
                    "BEAMTRACE_PARENT_ROOTDIR"
                ),
                restored_parent_environment(
                    "ERL_LIBS",
                    "BEAMTRACE_PARENT_ERL_LIBS_SET",
                    "BEAMTRACE_PARENT_ERL_LIBS"
                ),
                {"BEAMTRACE_AGENT_BEAM", false},
                {"BEAMTRACE_WEB_ROOT", false},
                {"BEAMTRACE_BUNDLED_RUNTIME", false},
                {"BEAMTRACE_PARENT_ERL_ROOTDIR_SET", false},
                {"BEAMTRACE_PARENT_ERL_ROOTDIR", false},
                {"BEAMTRACE_PARENT_ROOTDIR_SET", false},
                {"BEAMTRACE_PARENT_ROOTDIR", false},
                {"BEAMTRACE_PARENT_ERL_LIBS_SET", false},
                {"BEAMTRACE_PARENT_ERL_LIBS", false}
            ];
        _ -> Base
    end.

restored_parent_environment(Target, SetMarker, ValueMarker) ->
    case os:getenv(SetMarker) of
        "1" ->
            case os:getenv(ValueMarker) of
                false -> {Target, false};
                Value -> {Target, Value}
            end;
        _ -> {Target, false}
    end.

release_gated_command({gated_command, Port, Gate, _FinishGate, _HasFinishGate})
        when is_port(Port), is_binary(Gate) ->
    case file:write_file(Gate, <<"release">>, [binary, exclusive]) of
        ok -> {ok, nil};
        {error, eexist} -> {ok, nil};
        {error, Reason} -> {error, reason_binary({gate_release_failed, Reason})}
    end;
release_gated_command(_Handle) -> {error, <<"invalid gated command">>}.

release_gated_command_finish(
    {gated_command, Port, _Gate, FinishGate, true}
) when is_port(Port), is_binary(FinishGate) ->
    case file:write_file(FinishGate, <<"release">>, [binary, exclusive]) of
        ok -> {ok, nil};
        {error, eexist} -> {ok, nil};
        {error, Reason} -> {error, reason_binary({finish_gate_release_failed, Reason})}
    end;
release_gated_command_finish(
    {gated_command, Port, _Gate, _FinishGate, false}
) when is_port(Port) -> {ok, nil};
release_gated_command_finish(_Handle) -> {error, <<"invalid gated command">>}.

await_gated_command({gated_command, Port, Gate, FinishGate, _HasFinishGate}, TimeoutMs)
        when is_port(Port), is_binary(Gate), is_binary(FinishGate),
             is_integer(TimeoutMs), TimeoutMs > 0, TimeoutMs =< 86400000 ->
    Result = collect_port_until(
        Port,
        [],
        erlang:monotonic_time(millisecond) + TimeoutMs
    ),
    _ = file:delete(Gate),
    _ = file:delete(FinishGate),
    Result;
await_gated_command(_Handle, _TimeoutMs) ->
    {error, <<"invalid child timeout">>}.

stop_gated_command({gated_command, Port, Gate, FinishGate, _HasFinishGate})
        when is_port(Port), is_binary(Gate), is_binary(FinishGate) ->
    try port_close(Port)
    catch _:_ -> ok
    end,
    _ = file:delete(Gate),
    _ = file:delete(FinishGate),
    nil;
stop_gated_command(_Handle) -> nil.

gated_command_running({gated_command, Port, _Gate, _FinishGate, _HasFinishGate})
        when is_port(Port) ->
    case erlang:port_info(Port) of
        undefined -> false;
        _ -> true
    end;
gated_command_running(_Handle) -> false.

command_executable(Program) when is_binary(Program) ->
    case os:find_executable(binary_to_list(Program)) of
        false -> {error, reason_binary({executable_not_found, Program})};
        Executable -> {ok, Executable}
    end.

record_flags(Node, Cookie, IncludeGate) ->
    case {record_node_parts(Node), safe_flag_token(Cookie)} of
        {{ok, {Name, Host}}, true} ->
            NameFlag = case binary:match(Host, <<".">>) of
                nomatch -> "-sname " ++ binary_to_list(Name);
                _ -> "-name " ++ binary_to_list(Node)
            end,
            GateEval = case IncludeGate of
                true -> " -eval \"" ++ binary_to_list(start_gate_expression()) ++ "\"";
                false -> ""
            end,
            {ok,
                NameFlag ++ " -setcookie " ++ binary_to_list(Cookie)
                ++ GateEval};
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

direct_erl_program(Program) when is_binary(Program) ->
    Base = string:lowercase(filename:basename(binary_to_list(Program))),
    Base =:= "erl" orelse Base =:= "erl.exe".

insert_gate_arguments(Arguments) ->
    insert_finish_gate(insert_start_gate(Arguments, [])).

insert_start_gate([], Prefix) ->
    lists:reverse(Prefix) ++ [<<"-eval">>, start_gate_expression()];
insert_start_gate([Argument | _] = Rest, Prefix)
        when Argument =:= <<"-eval">>;
             Argument =:= <<"-s">>;
             Argument =:= <<"-run">> ->
    lists:reverse(Prefix) ++ [<<"-eval">>, start_gate_expression() | Rest];
insert_start_gate([Argument | Rest], Prefix) ->
    insert_start_gate(Rest, [Argument | Prefix]).

insert_finish_gate(Arguments) -> insert_finish_gate(Arguments, []).

insert_finish_gate([<<"-s">>, <<"init">>, <<"stop">> | Rest], Prefix) ->
    lists:reverse(Prefix)
    ++ [<<"-eval">>, finish_gate_expression(), <<"-s">>, <<"init">>, <<"stop">> | Rest];
insert_finish_gate([Argument | Rest], Prefix) ->
    insert_finish_gate(Rest, [Argument | Prefix]);
insert_finish_gate([], Prefix) ->
    lists:reverse(Prefix) ++ [<<"-eval">>, finish_gate_expression()].

start_gate_expression() ->
    <<"Wait = fun Loop() -> "
      "case file:read_file(os:getenv([$B,$E,$A,$M,$T,$R,$A,$C,$E,$_,"
      "$R,$E,$C,$O,$R,$D,$_, $G,$A,$T,$E])) of "
      "{ok, _} -> ok; _ -> timer:sleep(10), Loop() end end, Wait().">>.

finish_gate_expression() ->
    <<"Wait = fun Loop() -> "
      "case file:read_file(os:getenv([$B,$E,$A,$M,$T,$R,$A,$C,$E,$_,"
      "$R,$E,$C,$O,$R,$D,$_, $F,$I,$N,$I,$S,$H,$_, $G,$A,$T,$E])) of "
      "{ok, _} -> ok; _ -> timer:sleep(10), Loop() end end, Wait(), "
      "case os:getenv(\"BEAMTRACE_RECORD_ASSERT_CLEANUP\") of \"1\" -> "
      "case {seq_trace:get_system_tracer(), code:is_loaded(beamtrace_agent)} of "
      "{false, false} -> ok; _ -> erlang:halt(91) end; _ -> ok end.">>.

gate_path() ->
    Base = case os:getenv("TEMP") of
        false ->
            case os:getenv("TMP") of
                false -> ".";
                Tmp -> Tmp
            end;
        Temp -> Temp
    end,
    filename:join(Base, "beamtrace-record-" ++ binary_to_list(
        binary:part(hex(crypto:strong_rand_bytes(16)), 0, 24)
    ) ++ ".gate").

collect_port_until(Port, Acc, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} -> collect_port_until(Port, [Data | Acc], Deadline);
        {Port, {exit_status, Status}} ->
            {ok, {Status, iolist_to_binary(lists:reverse(Acc))}}
    after Remaining ->
        try port_close(Port)
        catch _:_ -> ok
        end,
        {error, <<"record command timed out">>}
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect_port(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {ok, {Status, iolist_to_binary(lists:reverse(Acc))}}
    after 86400000 ->
        try port_close(Port)
        catch _:_ -> ok
        end,
        {error, <<"record command timed out">>}
    end.

halt(Code) when is_integer(Code) -> erlang:halt(Code).

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>> || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
