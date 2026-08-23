%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_websocket_client_ffi).

-export([
    connect/3,
    send_text/2,
    receive_text/2,
    close/1,
    nonce/0,
    encode_client_text/2,
    decode_server_frame_binary/1,
    validate_upgrade/3,
    parse_wss_url/1
]).

-define(MAX_FRAME_BYTES, 1114112).
-define(MAX_HEADER_BYTES, 16384).
-define(WEBSOCKET_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).

connect(Url, Hello, UserAgent)
        when is_binary(Url), is_binary(Hello), is_binary(UserAgent),
             byte_size(Hello) =< ?MAX_HEADER_BYTES,
             byte_size(UserAgent) > 0, byte_size(UserAgent) =< 256 ->
    case valid_user_agent(UserAgent) of
        true ->
            case parse_wss_url(Url) of
                {ok, {Host, Port, Path, HostHeader}} ->
                    connect_wss(Host, Port, Path, HostHeader, Hello, UserAgent);
                Error -> Error
            end;
        false -> {error, <<"invalid_user_agent">>}
    end;
connect(_Url, _Hello, _UserAgent) -> {error, <<"invalid_channel_arguments">>}.

connect_wss(Host, Port, Path, HostHeader, Hello, UserAgent) ->
    try
        {ok, _} = application:ensure_all_started(ssl),
        Options = [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {depth, 6},
            {server_name_indication, binary_to_list(Host)},
            {customize_hostname_check, [
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
            ]},
            {versions, ['tlsv1.3', 'tlsv1.2']},
            {active, false},
            {packet, http_bin},
            {mode, binary}
        ],
        case ssl:connect(binary_to_list(Host), Port, Options, 10000) of
            {ok, Socket} ->
                websocket_upgrade(Socket, Path, HostHeader, Hello, UserAgent);
            {error, Reason} -> {error, reason_binary(Reason)}
        end
    catch
        _Class:CatchReason -> {error, reason_binary(CatchReason)}
    end.

websocket_upgrade(Socket, Path, HostHeader, Hello, UserAgent) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    Request = [
        <<"GET ">>, Path, <<" HTTP/1.1\r\nHost: ">>, HostHeader,
        <<"\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Key: ">>, Key,
        <<"\r\nSec-WebSocket-Version: 13\r\nUser-Agent: ">>, UserAgent,
        <<"\r\n\r\n">>
    ],
    case ssl:send(Socket, Request) of
        ok ->
            case read_upgrade(Socket, Key) of
                ok ->
                    case ssl:setopts(Socket, [{packet, raw}]) of
                        ok ->
                            case send_text({beamtrace_websocket, Socket}, Hello) of
                                {ok, nil} -> {ok, {beamtrace_websocket, Socket}};
                                {error, Reason} ->
                                    _ = ssl:close(Socket),
                                    {error, Reason}
                            end;
                        {error, Reason} ->
                            _ = ssl:close(Socket),
                            {error, reason_binary(Reason)}
                    end;
                {error, Reason} ->
                    _ = ssl:close(Socket),
                    {error, Reason}
            end;
        {error, Reason} ->
            _ = ssl:close(Socket),
            {error, reason_binary(Reason)}
    end.

valid_user_agent(UserAgent) ->
    binary:match(UserAgent, <<"\r">>) =:= nomatch andalso
        binary:match(UserAgent, <<"\n">>) =:= nomatch.

read_upgrade(Socket, Key) ->
    case ssl:recv(Socket, 0, 10000) of
        {ok, {http_response, {1, 1}, Status, _Reason}} ->
            read_upgrade_headers(Socket, Status, Key, [], 0);
        {ok, {http_response, _Version, _Status, _Reason}} ->
            {error, <<"invalid_http_version">>};
        {error, Reason} -> {error, reason_binary(Reason)};
        _ -> {error, <<"invalid_upgrade_response">>}
    end.

read_upgrade_headers(Socket, Status, Key, Headers, Size) ->
    case Size > ?MAX_HEADER_BYTES of
        true -> {error, <<"upgrade_headers_too_large">>};
        false ->
            case ssl:recv(Socket, 0, 10000) of
                {ok, {http_header, _Index, Name, _Reserved, Value}} ->
                    Header = {header_name(Name), as_binary(Value)},
                    Added = byte_size(element(1, Header)) + byte_size(element(2, Header)),
                    read_upgrade_headers(
                        Socket, Status, Key, [Header | Headers], Size + Added
                    );
                {ok, http_eoh} -> validate_upgrade(Status, Headers, Key);
                {error, Reason} -> {error, reason_binary(Reason)};
                _ -> {error, <<"invalid_upgrade_response">>}
            end
    end.

send_text({beamtrace_websocket, Socket}, Payload)
        when is_binary(Payload), byte_size(Payload) =< ?MAX_FRAME_BYTES ->
    Frame = encode_client_text(Payload, crypto:strong_rand_bytes(4)),
    case ssl:send(Socket, Frame) of
        ok -> {ok, nil};
        {error, Reason} -> {error, reason_binary(Reason)}
    end;
send_text(_Socket, _Payload) -> {error, <<"invalid_websocket">>}.

receive_text({beamtrace_websocket, Socket}, Timeout)
        when is_integer(Timeout), Timeout > 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    receive_text_until(Socket, Deadline);
receive_text(_Socket, _Timeout) -> {error, <<"invalid_websocket">>}.

receive_text_until(Socket, Deadline) ->
    case remaining_timeout(Deadline) of
        0 -> {error, <<"timeout">>};
        Remaining ->
            case read_server_frame(Socket, Remaining) of
                {ok, {text, Payload}} -> {ok, Payload};
                {ok, {ping, Payload}} ->
                    case send_control(Socket, 10, Payload) of
                        ok -> receive_text_until(Socket, Deadline);
                        {error, Reason} -> {error, Reason}
                    end;
                {ok, {pong, _Payload}} -> receive_text_until(Socket, Deadline);
                {ok, {close, _Payload}} -> {error, <<"closed">>};
                Error -> Error
            end
    end.

close({beamtrace_websocket, Socket}) ->
    _ = ssl:close(Socket),
    nil;
close(_Socket) -> nil.

nonce() -> crypto:strong_rand_bytes(24).

encode_client_text(Payload, Mask)
        when is_binary(Payload), is_binary(Mask), byte_size(Mask) =:= 4,
             byte_size(Payload) =< ?MAX_FRAME_BYTES ->
    Length = byte_size(Payload),
    Header = client_header(1, Length),
    <<Header/binary, Mask/binary, (mask_payload(Payload, Mask))/binary>>;
encode_client_text(_Payload, _Mask) -> <<>>.

client_header(Opcode, Length) when Length < 126 ->
    <<1:1, 0:3, Opcode:4, 1:1, Length:7>>;
client_header(Opcode, Length) when Length =< 65535 ->
    <<1:1, 0:3, Opcode:4, 1:1, 126:7, Length:16/big-unsigned-integer>>;
client_header(Opcode, Length) ->
    <<1:1, 0:3, Opcode:4, 1:1, 127:7, Length:64/big-unsigned-integer>>.

send_control(Socket, Opcode, Payload) when byte_size(Payload) =< 125 ->
    Mask = crypto:strong_rand_bytes(4),
    Header = client_header(Opcode, byte_size(Payload)),
    Frame = <<Header/binary, Mask/binary, (mask_payload(Payload, Mask))/binary>>,
    case ssl:send(Socket, Frame) of
        ok -> ok;
        {error, Reason} -> {error, reason_binary(Reason)}
    end;
send_control(_Socket, _Opcode, _Payload) -> {error, <<"invalid_control_frame">>}.

mask_payload(Payload, <<A, B, C, D>>) ->
    mask_payload(Payload, {A, B, C, D}, 0, []).

mask_payload(<<>>, _Mask, _Index, Accumulator) ->
    iolist_to_binary(lists:reverse(Accumulator));
mask_payload(<<Byte, Rest/binary>>, Mask, Index, Accumulator) ->
    MaskByte = element((Index rem 4) + 1, Mask),
    mask_payload(Rest, Mask, Index + 1, [Byte bxor MaskByte | Accumulator]).

decode_server_frame_binary(Frame) when is_binary(Frame) ->
    case decode_frame_binary(Frame) of
        {ok, {text, Payload}, <<>>} -> {ok, Payload};
        {ok, _Frame, _Rest} -> {error, <<"unexpected_frame">>};
        Error -> Error
    end.

decode_frame_binary(<<Fin:1, _Rsv:3, Opcode:4, Masked:1, LengthCode:7, Rest/binary>>) ->
    case {Fin, Masked} of
        {0, _} -> {error, <<"fragmented_frame">>};
        {_, 1} -> {error, <<"masked_server_frame">>};
        {1, 0} -> decode_frame_length(Opcode, LengthCode, Rest)
    end;
decode_frame_binary(_Frame) -> {error, <<"incomplete_frame">>}.

decode_frame_length(Opcode, Length, Rest) when Length < 126 ->
    decode_frame_payload(Opcode, Length, Rest);
decode_frame_length(Opcode, 126, <<Length:16/big-unsigned-integer, Rest/binary>>) ->
    decode_frame_payload(Opcode, Length, Rest);
decode_frame_length(Opcode, 127, <<0:1, Length:63/big-unsigned-integer, Rest/binary>>) ->
    decode_frame_payload(Opcode, Length, Rest);
decode_frame_length(_Opcode, 127, <<1:1, _Length:63, _Rest/binary>>) ->
    {error, <<"frame_too_large">>};
decode_frame_length(_Opcode, _Length, _Rest) -> {error, <<"incomplete_frame">>}.

decode_frame_payload(_Opcode, Length, _Rest) when Length > ?MAX_FRAME_BYTES ->
    {error, <<"frame_too_large">>};
decode_frame_payload(Opcode, Length, Rest) when byte_size(Rest) >= Length ->
    <<Payload:Length/binary, Tail/binary>> = Rest,
    case classify_frame(Opcode, Payload) of
        {ok, Frame} -> {ok, Frame, Tail};
        Error -> Error
    end;
decode_frame_payload(_Opcode, _Length, _Rest) -> {error, <<"incomplete_frame">>}.

classify_frame(1, Payload) ->
    case valid_utf8(Payload) of
        true -> {ok, {text, Payload}};
        false -> {error, <<"invalid_utf8">>}
    end;
classify_frame(8, Payload) when byte_size(Payload) =< 125 -> {ok, {close, Payload}};
classify_frame(9, Payload) when byte_size(Payload) =< 125 -> {ok, {ping, Payload}};
classify_frame(10, Payload) when byte_size(Payload) =< 125 -> {ok, {pong, Payload}};
classify_frame(8, _Payload) -> {error, <<"invalid_control_frame">>};
classify_frame(9, _Payload) -> {error, <<"invalid_control_frame">>};
classify_frame(10, _Payload) -> {error, <<"invalid_control_frame">>};
classify_frame(_Opcode, _Payload) -> {error, <<"unsupported_frame">>}.

read_server_frame(Socket, Timeout) ->
    case recv_exact(Socket, 2, Timeout, <<>>) of
        {ok, <<Fin:1, _Rsv:3, Opcode:4, Masked:1, LengthCode:7>>} ->
            case {Fin, Masked} of
                {0, _} -> {error, <<"fragmented_frame">>};
                {_, 1} -> {error, <<"masked_server_frame">>};
                {1, 0} -> read_server_length(Socket, Opcode, LengthCode, Timeout)
            end;
        Error -> Error
    end.

read_server_length(Socket, Opcode, Length, Timeout) when Length < 126 ->
    read_server_payload(Socket, Opcode, Length, Timeout);
read_server_length(Socket, Opcode, 126, Timeout) ->
    case recv_exact(Socket, 2, Timeout, <<>>) of
        {ok, <<Length:16/big-unsigned-integer>>} ->
            read_server_payload(Socket, Opcode, Length, Timeout);
        Error -> Error
    end;
read_server_length(Socket, Opcode, 127, Timeout) ->
    case recv_exact(Socket, 8, Timeout, <<>>) of
        {ok, <<0:1, Length:63/big-unsigned-integer>>} ->
            read_server_payload(Socket, Opcode, Length, Timeout);
        {ok, _} -> {error, <<"frame_too_large">>};
        Error -> Error
    end.

read_server_payload(_Socket, _Opcode, Length, _Timeout)
        when Length > ?MAX_FRAME_BYTES ->
    {error, <<"frame_too_large">>};
read_server_payload(Socket, Opcode, Length, Timeout) ->
    case recv_exact(Socket, Length, Timeout, <<>>) of
        {ok, Payload} -> classify_frame(Opcode, Payload);
        Error -> Error
    end.

recv_exact(_Socket, 0, _Timeout, Accumulator) -> {ok, Accumulator};
recv_exact(Socket, Remaining, Timeout, Accumulator) ->
    case ssl:recv(Socket, Remaining, Timeout) of
        {ok, Data} when byte_size(Data) =< Remaining ->
            recv_exact(
                Socket,
                Remaining - byte_size(Data),
                Timeout,
                <<Accumulator/binary, Data/binary>>
            );
        {error, timeout} -> {error, <<"timeout">>};
        {error, closed} -> {error, <<"closed">>};
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

validate_upgrade(101, Headers, Key) when is_list(Headers), is_binary(Key) ->
    Expected = base64:encode(crypto:hash(sha, <<Key/binary, ?WEBSOCKET_GUID/binary>>)),
    case {
        header_token(Headers, <<"upgrade">>, <<"websocket">>),
        header_token(Headers, <<"connection">>, <<"upgrade">>),
        header_value(Headers, <<"sec-websocket-accept">>)
    } of
        {true, true, Expected} -> ok;
        {false, _, _} -> {error, <<"invalid_upgrade_header">>};
        {_, false, _} -> {error, <<"invalid_connection_header">>};
        {_, _, _} -> {error, <<"invalid_websocket_accept">>}
    end;
validate_upgrade(_Status, _Headers, _Key) ->
    {error, <<"unexpected_http_status">>}.

header_value(Headers, Name) ->
    case lists:keyfind(Name, 1, Headers) of
        {Name, Value} -> trim_binary(Value);
        false -> <<>>
    end.

header_token(Headers, Name, Expected) ->
    Value = lowercase_binary(header_value(Headers, Name)),
    lists:member(Expected, [
        trim_binary(Token) || Token <- binary:split(Value, <<",">>, [global])
    ]).

parse_wss_url(Url) when is_binary(Url), byte_size(Url) =< 4096 ->
    try
        Parsed = uri_string:parse(Url),
        case {
            maps:get(scheme, Parsed, undefined),
            maps:get(host, Parsed, undefined),
            maps:is_key(userinfo, Parsed),
            maps:is_key(query, Parsed),
            maps:is_key(fragment, Parsed)
        } of
            {<<"wss">>, Host, false, false, false}
                    when is_binary(Host), byte_size(Host) > 0,
                         byte_size(Host) =< 253 ->
                Port = maps:get(port, Parsed, 443),
                Path0 = maps:get(path, Parsed, <<"/">>),
                Path = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
                case is_integer(Port) andalso Port > 0 andalso Port =< 65535
                        andalso byte_size(Path) =< 4096
                        andalso binary:at(Path, 0) =:= $/ of
                    true -> {ok, {Host, Port, Path, host_header(Host, Port)}};
                    false -> {error, <<"invalid_wss_url">>}
                end;
            _ -> {error, <<"invalid_wss_url">>}
        end
    catch
        _:_ -> {error, <<"invalid_wss_url">>}
    end;
parse_wss_url(_Url) -> {error, <<"invalid_wss_url">>}.

host_header(Host, Port) ->
    Bracketed = case binary:match(Host, <<":">>) of
        nomatch -> Host;
        _ -> <<"[", Host/binary, "]">>
    end,
    case Port of
        443 -> Bracketed;
        _ -> <<Bracketed/binary, ":", (integer_to_binary(Port))/binary>>
    end.

header_name(Name) when is_atom(Name) ->
    lowercase_binary(atom_to_binary(Name, latin1));
header_name(Name) -> lowercase_binary(as_binary(Name)).

lowercase_binary(Value) ->
    unicode:characters_to_binary(string:lowercase(binary_to_list(Value))).

trim_binary(Value) ->
    unicode:characters_to_binary(string:trim(binary_to_list(as_binary(Value)))).

valid_utf8(Value) ->
    case unicode:characters_to_list(Value, utf8) of
        List when is_list(List) -> true;
        _ -> false
    end.

remaining_timeout(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

as_binary(Value) when is_binary(Value) -> Value;
as_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
as_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
as_binary(Value) -> unicode:characters_to_binary(io_lib:format("~0p", [Value])).

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
