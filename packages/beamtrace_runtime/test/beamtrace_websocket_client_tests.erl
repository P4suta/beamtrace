%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_websocket_client_tests).
-include_lib("eunit/include/eunit.hrl").

client_text_frames_are_masked_test() ->
    Frame = beamtrace_websocket_client_ffi:encode_client_text(
        <<"hello">>, <<1, 2, 3, 4>>
    ),
    ?assertEqual(
        <<16#81, 16#85, 1, 2, 3, 4, 105, 103, 111, 104, 110>>,
        Frame
    ).

server_text_frame_parser_rejects_masking_fragmentation_and_large_frames_test() ->
    ?assertEqual(
        {ok, <<"hello">>},
        beamtrace_websocket_client_ffi:decode_server_frame_binary(
            <<16#81, 5, "hello">>
        )
    ),
    ?assertEqual(
        {error, <<"masked_server_frame">>},
        beamtrace_websocket_client_ffi:decode_server_frame_binary(
            <<16#81, 16#81, 0, 0, 0, 0, "x">>
        )
    ),
    ?assertEqual(
        {error, <<"fragmented_frame">>},
        beamtrace_websocket_client_ffi:decode_server_frame_binary(
            <<16#01, 1, "x">>
        )
    ),
    ?assertEqual(
        {error, <<"frame_too_large">>},
        beamtrace_websocket_client_ffi:decode_server_frame_binary(
            <<16#81, 127, 0, 0, 0, 0, 0, 17, 0, 1>>
        )
    ).

upgrade_response_is_bound_to_the_client_nonce_test() ->
    Key = <<"dGhlIHNhbXBsZSBub25jZQ==">>,
    Accept = base64:encode(crypto:hash(
        sha,
        <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>
    )),
    Headers = [
        {<<"upgrade">>, <<"websocket">>},
        {<<"connection">>, <<"keep-alive, Upgrade">>},
        {<<"sec-websocket-accept">>, Accept}
    ],
    ?assertEqual(
        ok,
        beamtrace_websocket_client_ffi:validate_upgrade(101, Headers, Key)
    ),
    ?assertEqual(
        {error, <<"unexpected_http_status">>},
        beamtrace_websocket_client_ffi:validate_upgrade(302, Headers, Key)
    ),
    ?assertEqual(
        {error, <<"invalid_websocket_accept">>},
        beamtrace_websocket_client_ffi:validate_upgrade(
            101,
            lists:keyreplace(
                <<"sec-websocket-accept">>,
                1,
                Headers,
                {<<"sec-websocket-accept">>, <<"wrong">>}
            ),
            Key
        )
    ).

wss_url_parser_rejects_credential_query_and_fragment_test() ->
    ?assertEqual(
        {ok, {<<"hub.example">>, 443, <<"/api/relay/v1/channel/relay-1">>,
            <<"hub.example">>}},
        beamtrace_websocket_client_ffi:parse_wss_url(
            <<"wss://hub.example/api/relay/v1/channel/relay-1">>
        )
    ),
    ?assertMatch(
        {error, _},
        beamtrace_websocket_client_ffi:parse_wss_url(
            <<"wss://user:pass@hub.example/channel">>
        )
    ),
    ?assertMatch(
        {error, _},
        beamtrace_websocket_client_ffi:parse_wss_url(
            <<"wss://hub.example/channel?token=secret">>
        )
    ),
    ?assertMatch(
        {error, _},
        beamtrace_websocket_client_ffi:parse_wss_url(
            <<"wss://hub.example/channel#fragment">>
        )
    ).
