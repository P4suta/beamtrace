%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_team_config_ffi).

-include_lib("kernel/include/file.hrl").

-export([environment_pairs/0, read_jwks_file/1]).

-define(MAX_JWKS_BYTES, 1048576).
-define(MAX_PATH_BYTES, 4096).

environment_pairs() ->
    lists:filtermap(fun environment_pair/1, [
        {<<"team">>, "BEAMTRACE_TEAM"},
        {<<"bind">>, "BEAMTRACE_BIND"},
        {<<"data_dir">>, "BEAMTRACE_DATA_DIR"},
        {<<"port">>, "BEAMTRACE_PORT"},
        {<<"origin">>, "BEAMTRACE_ORIGIN"},
        {<<"oidc_authorization_endpoint">>, "BEAMTRACE_OIDC_AUTHORIZATION_ENDPOINT"},
        {<<"oidc_token_endpoint">>, "BEAMTRACE_OIDC_TOKEN_ENDPOINT"},
        {<<"oidc_issuer">>, "BEAMTRACE_OIDC_ISSUER"},
        {<<"oidc_client_id">>, "BEAMTRACE_OIDC_CLIENT_ID"},
        {<<"oidc_client_secret">>, "BEAMTRACE_OIDC_CLIENT_SECRET"},
        {<<"oidc_redirect_uri">>, "BEAMTRACE_OIDC_REDIRECT_URI"},
        {<<"oidc_jwks_file">>, "BEAMTRACE_OIDC_JWKS_FILE"},
        {<<"oidc_group_roles">>, "BEAMTRACE_OIDC_GROUP_ROLES"},
        {<<"project">>, "BEAMTRACE_PROJECT"},
        {<<"environment">>, "BEAMTRACE_ENVIRONMENT"},
        {<<"retention_days">>, "BEAMTRACE_RETENTION_DAYS"},
        {<<"relay_max_events">>, "BEAMTRACE_RELAY_MAX_EVENTS"},
        {<<"relay_max_bytes">>, "BEAMTRACE_RELAY_MAX_BYTES"},
        {<<"enrollment_ttl_ms">>, "BEAMTRACE_ENROLLMENT_TTL_MS"},
        {<<"cookie">>, "BEAMTRACE_COOKIE"},
        {<<"cookie_file">>, "BEAMTRACE_COOKIE_FILE"}
    ]).

environment_pair({Key, Name}) ->
    case os:getenv(Name) of
        false -> false;
        Value -> {true, {Key, unicode:characters_to_binary(Value)}}
    end.

read_jwks_file(Path) when is_binary(Path), byte_size(Path) > 0,
                          byte_size(Path) =< ?MAX_PATH_BYTES ->
    PathString = binary_to_list(Path),
    case file:read_file_info(PathString) of
        {ok, #file_info{type = regular, size = Size}}
                when Size > 0, Size =< ?MAX_JWKS_BYTES ->
            case file:read_file(PathString) of
                {ok, Contents} when byte_size(Contents) =< ?MAX_JWKS_BYTES ->
                    {ok, Contents};
                {ok, _Contents} -> {error, <<"too_large">>};
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {ok, #file_info{type = regular}} -> {error, <<"invalid_size">>};
        {ok, _Info} -> {error, <<"not_regular_file">>};
        {error, Reason} -> {error, reason_binary(Reason)}
    end;
read_jwks_file(_Path) ->
    {error, <<"invalid_path">>}.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
