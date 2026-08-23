%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_cli_ffi).

-export([
    read_cookie_file/1,
    read_cookie_default/0,
    write_text/2,
    random_secret/0,
    capture_id/0,
    web_root/0,
    doctor/0,
    run_command/1,
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
