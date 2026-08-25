%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_team_tui_ffi).

-include_lib("kernel/include/file.hrl").

-export([read_session_file/1, fetch_trace_page/2]).

-define(MAX_SESSION_BYTES, 512).
-define(MAX_RESPONSE_BYTES, 1048576).

read_session_file(PathBinary) when is_binary(PathBinary) ->
    Path = binary_to_list(PathBinary),
    case secure_regular_file(Path) of
        ok ->
            case file:read_file(Path) of
                {ok, Content} -> normalize_session(Content);
                {error, _Reason} ->
                    {error, <<"team session file could not be read">>}
            end;
        {error, _} = Error -> Error
    end;
read_session_file(_Path) -> {error, <<"team session file path is invalid">>}.

fetch_trace_page(BaseBinary, SessionBinary)
        when is_binary(BaseBinary), is_binary(SessionBinary) ->
    case {validated_url(BaseBinary), normalize_session(SessionBinary)} of
        {{ok, {Url, Host, Scheme}}, {ok, Session}} ->
            request_traces(Url, Host, Scheme, Session);
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
fetch_trace_page(_Base, _Session) ->
    {error, <<"team trace request is invalid">>}.

secure_regular_file(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size, mode = Mode}}
                when Size > 0, Size =< ?MAX_SESSION_BYTES ->
            case os:type() of
                {win32, _} -> ok;
                _ when Mode band 8#077 =:= 0 -> ok;
                _ -> {error, <<"team session file permissions must be 0600">>}
            end;
        {ok, #file_info{type = regular}} ->
            {error, <<"team session file is empty or too large">>};
        _ -> {error, <<"team session file must be a regular file">>}
    end.

normalize_session(Content) ->
    try
        Session = unicode:characters_to_binary(
            string:trim(binary_to_list(Content))
        ),
        Size = byte_size(Session),
        case Size > 0 andalso Size =< ?MAX_SESSION_BYTES
                andalso lists:all(fun valid_cookie_byte/1,
                                  binary_to_list(Session)) of
            true -> {ok, Session};
            false -> {error, <<"team session file contains an invalid value">>}
        end
    catch
        _:_ -> {error, <<"team session file contains an invalid value">>}
    end.

valid_cookie_byte(Byte) ->
    (Byte >= $a andalso Byte =< $z)
        orelse (Byte >= $A andalso Byte =< $Z)
        orelse (Byte >= $0 andalso Byte =< $9)
        orelse Byte =:= $-
        orelse Byte =:= $_.

validated_url(BaseBinary) ->
    try
        Base0 = string:trim(binary_to_list(BaseBinary), trailing, "/"),
        Parsed = uri_string:parse(Base0),
        Scheme = maps:get(scheme, Parsed, undefined),
        Host = maps:get(host, Parsed, undefined),
        Path = maps:get(path, Parsed, ""),
        UserInfo = maps:get(userinfo, Parsed, undefined),
        Query = maps:get(query, Parsed, undefined),
        Fragment = maps:get(fragment, Parsed, undefined),
        case valid_origin(Scheme, Host, Path, UserInfo, Query, Fragment) of
            true ->
                Url = Base0 ++ "/api/v1/traces?limit=100",
                {ok, {Url, Host, Scheme}};
            false -> {error, <<"team server URL is not a secure origin">>}
        end
    catch
        _:_ -> {error, <<"team server URL is invalid">>}
    end.

valid_origin(Scheme, Host, Path, undefined, undefined, undefined)
        when is_list(Host), Host =/= [], (Path =:= "" orelse Path =:= "/") ->
    Scheme =:= "https" orelse (Scheme =:= "http" andalso is_loopback(Host));
valid_origin(_, _, _, _, _, _) -> false.

is_loopback("127.0.0.1") -> true;
is_loopback("::1") -> true;
is_loopback("localhost") -> true;
is_loopback(_) -> false.

request_traces(Url, Host, Scheme, Session) ->
    try
        {ok, _} = application:ensure_all_started(inets),
        {ok, _} = application:ensure_all_started(ssl),
        HttpOptions = [
            {connect_timeout, 3000},
            {timeout, 5000},
            {autoredirect, false}
            | tls_options(Scheme, Host)
        ],
        Headers = [
            {"accept", "application/json"},
            {"cookie", "beamtrace_session=" ++ binary_to_list(Session)}
        ],
        case httpc:request(
            get,
            {Url, Headers},
            HttpOptions,
            [{body_format, binary}]
        ) of
            {ok, {{_Version, 200, _Reason}, _ResponseHeaders, Body}}
                    when byte_size(Body) =< ?MAX_RESPONSE_BYTES ->
                {ok, Body};
            {ok, {{_Version, 200, _Reason}, _ResponseHeaders, _Body}} ->
                {error, <<"team trace response exceeded 1 MiB">>};
            {ok, {{_Version, 401, _Reason}, _Headers, _Body}} ->
                {error, <<"team session is invalid or expired">>};
            {ok, {{_Version, 403, _Reason}, _Headers, _Body}} ->
                {error, <<"team session cannot view traces">>};
            {ok, {{_Version, _Status, _Reason}, _Headers, _Body}} ->
                {error, <<"team trace request failed">>};
            {error, _Reason} ->
                {error, <<"team trace transport failed">>}
        end
    catch
        _:_ -> {error, <<"team trace transport failed">>}
    end.

tls_options("https", Host) ->
    [{ssl, [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {depth, 6},
        {server_name_indication, Host},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ]}];
tls_options("http", _Host) -> [].
