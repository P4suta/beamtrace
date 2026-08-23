%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_relay_http_ffi).

-export([post_json/2]).

post_json(Url, Body) when is_binary(Url), is_binary(Body) ->
    try
        {ok, _} = application:ensure_all_started(ssl),
        {ok, _} = application:ensure_all_started(inets),
        SslOptions = [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {depth, 6},
            {customize_hostname_check, [
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
            ]}
        ],
        HttpOptions = [
            {connect_timeout, 5000},
            {timeout, 15000},
            {autoredirect, false},
            {ssl, SslOptions}
        ],
        Request = {
            binary_to_list(Url),
            [{"accept", "application/json"}],
            "application/json",
            Body
        },
        case httpc:request(post, Request, HttpOptions, [{body_format, binary}]) of
            {ok, {{_Version, Status, _Reason}, _Headers, ResponseBody}} ->
                {ok, {Status, ResponseBody}};
            {error, RequestReason} ->
                {error, reason_binary(RequestReason)}
        end
    catch
        Class:CatchReason -> {error, reason_binary({Class, CatchReason})}
    end.

reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
