%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_oidc_discovery_ffi).

-export([
    get_json/2,
    remember_provider/3,
    cached_jwks/2,
    refresh_jwks/2,
    cache_refreshed_jwks/2
]).

-define(CACHE_KEY, {?MODULE, provider}).

get_json(Url, MaximumBytes)
        when is_binary(Url), is_integer(MaximumBytes), MaximumBytes > 0,
             MaximumBytes =< 1048576 ->
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
        Request = {binary_to_list(Url), [{"accept", "application/json"}]},
        case httpc:request(get, Request, HttpOptions, [{body_format, binary}]) of
            {ok, {{_Version, Status, _Reason}, _Headers, Body}}
                    when byte_size(Body) =< MaximumBytes ->
                {ok, {Status, Body}};
            {ok, {{_Version, _Status, _Reason}, _Headers, _Body}} ->
                {error, <<"response_too_large">>};
            {error, Reason} -> {error, reason_binary(Reason)}
        end
    catch
        Class:CatchReason -> {error, reason_binary({Class, CatchReason})}
    end;
get_json(_Url, _MaximumBytes) -> {error, <<"invalid_request">>}.

remember_provider(Issuer, JwksUri, Jwks)
        when is_binary(Issuer), is_binary(JwksUri), is_binary(Jwks) ->
    persistent_term:put(?CACHE_KEY, {Issuer, JwksUri, Jwks}),
    nil.

cached_jwks(Issuer, Fallback) when is_binary(Issuer), is_binary(Fallback) ->
    case persistent_term:get(?CACHE_KEY, undefined) of
        {Issuer, _JwksUri, Jwks} -> Jwks;
        _ -> Fallback
    end.

refresh_jwks(Issuer, MaximumBytes) when is_binary(Issuer) ->
    case persistent_term:get(?CACHE_KEY, undefined) of
        {Issuer, JwksUri, _OldJwks} ->
            case get_json(JwksUri, MaximumBytes) of
                {ok, {200, Jwks}} -> {ok, Jwks};
                {ok, {Status, _}} ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("unexpected_status:~B", [Status])
                    )};
                Error -> Error
            end;
        _ -> {error, <<"offline_jwks">>}
    end.

cache_refreshed_jwks(Issuer, Jwks) when is_binary(Issuer), is_binary(Jwks) ->
    case persistent_term:get(?CACHE_KEY, undefined) of
        {Issuer, JwksUri, _OldJwks} ->
            persistent_term:put(?CACHE_KEY, {Issuer, JwksUri, Jwks});
        _ -> ok
    end,
    nil.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
