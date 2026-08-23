%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_oidc_http_ffi).

-export([form_body/4, valid_pkce_verifier/1, post_form/2]).

form_body(ClientId, Code, RedirectUri, Verifier)
        when is_binary(ClientId), is_binary(Code), is_binary(RedirectUri),
             is_binary(Verifier) ->
    join_query([
        {<<"grant_type">>, <<"authorization_code">>},
        {<<"client_id">>, ClientId},
        {<<"code">>, Code},
        {<<"redirect_uri">>, RedirectUri},
        {<<"code_verifier">>, Verifier}
    ]).

valid_pkce_verifier(Value) when is_binary(Value) ->
    Size = byte_size(Value),
    Size >= 43 andalso Size =< 128
        andalso lists:all(fun valid_verifier_byte/1, binary_to_list(Value));
valid_pkce_verifier(_Value) ->
    false.

post_form(Url, Body) when is_binary(Url), is_binary(Body) ->
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
            "application/x-www-form-urlencoded",
            Body
        },
        case httpc:request(post, Request, HttpOptions, [{body_format, binary}]) of
            {ok, {{_Version, Status, _Reason}, _Headers, ResponseBody}} ->
                {ok, {Status, ResponseBody}};
            {error, Reason} ->
                {error, reason_binary(Reason)}
        end
    catch
        Class:CatchReason -> {error, reason_binary({Class, CatchReason})}
    end.

join_query(Fields) ->
    iolist_to_binary(lists:join(<<"&">>, [
        [percent_encode(Key), <<"=">>, percent_encode(Value)]
        || {Key, Value} <- Fields
    ])).

percent_encode(Value) ->
    << <<(encode_byte(Byte))/binary>> || <<Byte>> <= Value >>.

encode_byte(Byte) when
        (Byte >= $a andalso Byte =< $z) orelse
        (Byte >= $A andalso Byte =< $Z) orelse
        (Byte >= $0 andalso Byte =< $9) orelse
        Byte =:= $- orelse Byte =:= $. orelse Byte =:= $_ orelse Byte =:= $~ ->
    <<Byte>>;
encode_byte(Byte) ->
    <<$%, (hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $A + Value - 10.

valid_verifier_byte(Byte) ->
    (Byte >= $a andalso Byte =< $z) orelse
    (Byte >= $A andalso Byte =< $Z) orelse
    (Byte >= $0 andalso Byte =< $9) orelse
    Byte =:= $- orelse Byte =:= $. orelse Byte =:= $_ orelse Byte =:= $~.

reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
