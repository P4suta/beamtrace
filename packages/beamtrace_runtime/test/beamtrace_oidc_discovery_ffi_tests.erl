%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_oidc_discovery_ffi_tests).

-include_lib("eunit/include/eunit.hrl").

chunked_response_is_collected_test() ->
    with_server(
        fun(Socket) ->
            ok = gen_tcp:send(Socket, [
                <<"HTTP/1.1 200 OK\r\n">>,
                <<"content-type: application/json\r\n">>,
                <<"transfer-encoding: chunked\r\n">>,
                <<"connection: close\r\n\r\n">>,
                <<"2\r\n{}\r\n0\r\n\r\n">>
            ])
        end,
        fun(Url) ->
            ?assertEqual(
                {ok, {200, <<"{}">>}},
                beamtrace_oidc_discovery_ffi:get_json(Url, 1024)
            )
        end
    ).

oversized_chunked_response_is_rejected_before_stream_end_test() ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(inets),
    with_server(
        fun(Socket) ->
            ok = gen_tcp:send(Socket, [
                <<"HTTP/1.1 200 OK\r\n">>,
                <<"content-type: application/json\r\n">>,
                <<"transfer-encoding: chunked\r\n">>,
                <<"connection: close\r\n\r\n">>,
                <<"800\r\n">>,
                binary:copy(<<"x">>, 2048),
                <<"\r\n">>
            ]),
            timer:sleep(100),
            _ = gen_tcp:send(Socket, <<"1\r\ny\r\n">>),
            timer:sleep(4000),
            _ = gen_tcp:send(Socket, <<"0\r\n\r\n">>),
            ok
        end,
        fun(Url) ->
            Started = erlang:monotonic_time(millisecond),
            ?assertEqual(
                {error, <<"response_too_large">>},
                beamtrace_oidc_discovery_ffi:get_json(Url, 1024)
            ),
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            ?assert(Elapsed < 2500)
        end
    ).

with_server(Respond, Test) ->
    {ok, Listener} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {packet, raw},
        {reuseaddr, true},
        {ip, {127, 0, 0, 1}}
    ]),
    {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Listener),
    Server = spawn(fun() -> serve_once(Listener, Respond) end),
    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/oidc", [Port])),
    try Test(Url)
    after
        exit(Server, kill),
        _ = gen_tcp:close(Listener)
    end.

serve_once(Listener, Respond) ->
    case gen_tcp:accept(Listener, 5000) of
        {ok, Socket} ->
            ok = gen_tcp:close(Listener),
            {ok, _Request} = gen_tcp:recv(Socket, 0, 5000),
            _ = Respond(Socket),
            gen_tcp:close(Socket);
        {error, _Reason} ->
            ok
    end.
