%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_oidc_ffi).

-export([authorization_url/6]).

authorization_url(Endpoint, ClientId, RedirectUri, State, Nonce, Challenge)
        when is_binary(Endpoint), is_binary(ClientId), is_binary(RedirectUri),
             is_binary(State), is_binary(Nonce), is_binary(Challenge) ->
    case safe_https_endpoint(Endpoint) of
        true ->
            Query = join_query([
                {<<"response_type">>, <<"code">>},
                {<<"client_id">>, ClientId},
                {<<"redirect_uri">>, RedirectUri},
                {<<"scope">>, <<"openid">>},
                {<<"state">>, State},
                {<<"nonce">>, Nonce},
                {<<"code_challenge">>, Challenge},
                {<<"code_challenge_method">>, <<"S256">>}
            ]),
            {ok, <<Endpoint/binary, "?", Query/binary>>};
        false ->
            {error, <<"invalid_authorization_endpoint">>}
    end.

safe_https_endpoint(Endpoint) ->
    try uri_string:parse(Endpoint) of
        Parsed when is_map(Parsed) ->
            maps:get(scheme, Parsed, undefined) =:= <<"https">>
                andalso maps:is_key(host, Parsed)
                andalso not maps:is_key(userinfo, Parsed)
                andalso not maps:is_key(query, Parsed)
                andalso not maps:is_key(fragment, Parsed);
        _ -> false
    catch
        _:_ -> false
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
