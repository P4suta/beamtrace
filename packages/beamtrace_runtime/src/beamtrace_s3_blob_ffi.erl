%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_s3_blob_ffi).

-export([valid_config/1, put/3, read/2, delete/2, authorization_for_test/9]).

-define(MAX_BLOB_BYTES, 1048576).
-define(MAX_KEY_BYTES, 1024).
-define(MAX_CA_BUNDLE_BYTES, 1048576).

valid_config({config, Endpoint, Bucket, Region, Prefix}) ->
    valid_endpoint(Endpoint)
        andalso valid_bucket(Bucket)
        andalso valid_region(Region)
        andalso valid_prefix(Prefix);
valid_config(_) -> false.

put(Config, Key, Payload)
        when is_binary(Payload), byte_size(Payload) > 0,
             byte_size(Payload) =< ?MAX_BLOB_BYTES ->
    case valid_config(Config) andalso valid_key(Key) of
        false -> {error, <<"invalid_blob_payload">>};
        true -> put_valid(Config, Key, Payload, 0)
    end;
put(_Config, _Key, _Payload) -> {error, <<"invalid_blob_payload">>}.

read(Config, Key) ->
    case valid_config(Config) andalso valid_key(Key) of
        false -> {error, <<"invalid_blob_key">>};
        true -> read_valid(Config, Key)
    end.

delete(Config, Key) ->
    case valid_config(Config) andalso valid_key(Key) of
        false -> {error, <<"invalid_blob_key">>};
        true ->
            case signed_request(Config, delete, Key, <<>>, []) of
                {ok, Status, _Headers, _Body} when Status >= 200, Status < 300 ->
                    {ok, nil};
                {ok, 404, _Headers, _Body} -> {ok, nil};
                {ok, _Status, _Headers, _Body} -> {error, <<"s3_request_failed">>};
                Error -> Error
            end
    end.

put_valid(Config, Key, Payload, Retry) ->
    Digest = hex(crypto:hash(sha256, Payload)),
    Headers = [
        {<<"if-none-match">>, <<"*">>},
        {<<"x-amz-meta-beamtrace-sha256">>, Digest}
    ],
    case signed_request(Config, put, Key, Payload, Headers) of
        {ok, Status, _ResponseHeaders, _Body} when Status >= 200, Status < 300 ->
            {ok, {Key, Digest, byte_size(Payload)}};
        {ok, 412, _ResponseHeaders, _Body} -> compare_existing(Config, Key, Payload);
        {ok, 409, _ResponseHeaders, _Body} when Retry < 1 ->
            put_valid(Config, Key, Payload, Retry + 1);
        {ok, _Status, _ResponseHeaders, _Body} ->
            {error, <<"s3_request_failed">>};
        Error -> Error
    end.

compare_existing(Config, Key, Payload) ->
    case read_valid(Config, Key) of
        {ok, Payload} ->
            Digest = hex(crypto:hash(sha256, Payload)),
            {ok, {Key, Digest, byte_size(Payload)}};
        {ok, _Different} -> {error, <<"blob_conflict">>};
        Error -> Error
    end.

read_valid(Config, Key) ->
    case signed_request(Config, get, Key, <<>>, []) of
        {ok, 200, _Headers, Body}
                when byte_size(Body) > 0, byte_size(Body) =< ?MAX_BLOB_BYTES ->
            {ok, Body};
        {ok, 200, _Headers, _Body} -> {error, <<"invalid_blob_payload">>};
        {ok, 404, _Headers, _Body} -> {error, <<"blob_not_found">>};
        {ok, _Status, _Headers, _Body} -> {error, <<"s3_request_failed">>};
        Error -> Error
    end.

signed_request(Config, Method, Key, Payload, AdditionalHeaders) ->
    case credentials() of
        {error, _} = Error -> Error;
        {ok, AccessKey, SecretKey, SessionToken} ->
            request_with_credentials(
                Config,
                Method,
                Key,
                Payload,
                AdditionalHeaders,
                AccessKey,
                SecretKey,
                SessionToken
            )
    end.

request_with_credentials(
        {config, Endpoint, Bucket, Region, Prefix},
        Method,
        Key,
        Payload,
        AdditionalHeaders,
        AccessKey,
        SecretKey,
        SessionToken
    ) ->
    Parsed = uri_string:parse(Endpoint),
    Host = host_header(Parsed),
    ObjectKey = join_prefix(Prefix, Key),
    CanonicalUri = <<"/", (uri_encode(Bucket))/binary, "/", (uri_encode_key(ObjectKey))/binary>>,
    Url = <<(trim_trailing_slash(Endpoint))/binary, CanonicalUri/binary>>,
    AmzDate = amz_date(),
    TokenHeaders = case SessionToken of
        none -> [];
        Token -> [{<<"x-amz-security-token">>, Token}]
    end,
    Headers0 = AdditionalHeaders ++ TokenHeaders,
    Authorization = authorization(
        method_binary(Method),
        CanonicalUri,
        Host,
        Region,
        AccessKey,
        SecretKey,
        AmzDate,
        Headers0,
        Payload
    ),
    PayloadHash = hex(crypto:hash(sha256, Payload)),
    RequestHeaders = [
        {"authorization", binary_to_list(Authorization)},
        {"host", binary_to_list(Host)},
        {"x-amz-content-sha256", binary_to_list(PayloadHash)},
        {"x-amz-date", binary_to_list(AmzDate)}
        | [{binary_to_list(Name), binary_to_list(Value)} || {Name, Value} <- Headers0]
    ],
    http_request(Method, Url, RequestHeaders, Payload).

http_request(Method, Url, Headers, Payload) ->
    case ca_options() of
        {ok, CaOptions} ->
            http_request_with_ca(Method, Url, Headers, Payload, CaOptions);
        {error, _} = Error -> Error
    end.

http_request_with_ca(Method, Url, Headers, Payload, CaOptions) ->
    try
        {ok, _} = application:ensure_all_started(ssl),
        {ok, _} = application:ensure_all_started(inets),
        SslOptions = [
            {verify, verify_peer},
            {depth, 6},
            {customize_hostname_check, [
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
            ]}
        ] ++ CaOptions,
        HttpOptions = [
            {connect_timeout, 5000},
            {timeout, 15000},
            {autoredirect, false},
            {ssl, SslOptions}
        ],
        Request = case Method of
            put -> {binary_to_list(Url), Headers, "application/octet-stream", Payload};
            _ -> {binary_to_list(Url), Headers}
        end,
        case httpc:request(Method, Request, HttpOptions, [{body_format, binary}]) of
            {ok, {{_Version, Status, _Reason}, ResponseHeaders, Body}} ->
                {ok, Status, ResponseHeaders, Body};
            {error, _Reason} -> {error, <<"s3_transport_failed">>}
        end
    catch
        _:_ -> {error, <<"s3_transport_failed">>}
    end.

ca_options() ->
    try
        case os:getenv("AWS_CA_BUNDLE") of
            false -> {ok, [{cacerts, public_key:cacerts_get()}]};
            Path -> custom_ca_options(Path)
        end
    catch
        _:_ -> {error, <<"s3_ca_bundle_invalid">>}
    end.

custom_ca_options(Path) ->
    case read_bounded_file(Path, ?MAX_CA_BUNDLE_BYTES) of
        {ok, Pem} ->
            Entries = public_key:pem_decode(Pem),
            Certificates = [
                Der
                || {Type, Der, not_encrypted} <- Entries,
                   Type =:= 'Certificate' orelse Type =:= 'TrustedCertificate'
            ],
            case Certificates of
                [] -> {error, <<"s3_ca_bundle_invalid">>};
                _ -> {ok, [{cacertfile, Path}]}
            end;
        {error, _} -> {error, <<"s3_ca_bundle_invalid">>}
    end.

read_bounded_file(Path, Maximum) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Handle} ->
            try
                case file:read(Handle, Maximum + 1) of
                    {ok, Contents} when byte_size(Contents) > 0,
                                        byte_size(Contents) =< Maximum ->
                        {ok, Contents};
                    _ -> {error, invalid_file}
                end
            after
                file:close(Handle)
            end;
        {error, _} -> {error, invalid_file}
    end.

authorization_for_test(
        Method,
        CanonicalUri,
        Host,
        Region,
        AccessKey,
        SecretKey,
        AmzDate,
        AdditionalHeaders,
        Payload
    ) ->
    authorization(
        Method,
        CanonicalUri,
        Host,
        Region,
        AccessKey,
        SecretKey,
        AmzDate,
        AdditionalHeaders,
        Payload
    ).

authorization(
        Method,
        CanonicalUri,
        Host,
        Region,
        AccessKey,
        SecretKey,
        AmzDate,
        AdditionalHeaders,
        Payload
    ) ->
    PayloadHash = hex(crypto:hash(sha256, Payload)),
    SigningHeaders = lists:sort([
        {<<"host">>, normalize_header(Host)},
        {<<"x-amz-content-sha256">>, PayloadHash},
        {<<"x-amz-date">>, AmzDate}
        | [{lower(Name), normalize_header(Value)} || {Name, Value} <- AdditionalHeaders]
    ]),
    CanonicalHeaders = iolist_to_binary([
        [Name, <<":">>, Value, <<"\n">>] || {Name, Value} <- SigningHeaders
    ]),
    SignedHeaders = iolist_to_binary(
        lists:join(<<";">>, [Name || {Name, _} <- SigningHeaders])
    ),
    CanonicalRequest = iolist_to_binary([
        Method, <<"\n">>, CanonicalUri, <<"\n\n">>, CanonicalHeaders,
        <<"\n">>, SignedHeaders, <<"\n">>, PayloadHash
    ]),
    <<Date:8/binary, _/binary>> = AmzDate,
    Scope = <<Date/binary, "/", Region/binary, "/s3/aws4_request">>,
    StringToSign = iolist_to_binary([
        <<"AWS4-HMAC-SHA256\n">>, AmzDate, <<"\n">>, Scope, <<"\n">>,
        hex(crypto:hash(sha256, CanonicalRequest))
    ]),
    DateKey = hmac(<<"AWS4", SecretKey/binary>>, Date),
    RegionKey = hmac(DateKey, Region),
    ServiceKey = hmac(RegionKey, <<"s3">>),
    SigningKey = hmac(ServiceKey, <<"aws4_request">>),
    Signature = hex(hmac(SigningKey, StringToSign)),
    iolist_to_binary([
        <<"AWS4-HMAC-SHA256 Credential=">>, AccessKey, <<"/">>, Scope,
        <<",SignedHeaders=">>, SignedHeaders, <<",Signature=">>, Signature
    ]).

credentials() ->
    case {os:getenv("AWS_ACCESS_KEY_ID"), os:getenv("AWS_SECRET_ACCESS_KEY")} of
        {false, _} -> {error, <<"s3_credentials_unavailable">>};
        {_, false} -> {error, <<"s3_credentials_unavailable">>};
        {Access0, Secret0} ->
            Access = unicode:characters_to_binary(Access0),
            Secret = unicode:characters_to_binary(Secret0),
            Token = case os:getenv("AWS_SESSION_TOKEN") of
                false -> none;
                Token0 -> unicode:characters_to_binary(Token0)
            end,
            case valid_credential(Access, 256)
                    andalso valid_credential(Secret, 4096)
                    andalso valid_optional_token(Token) of
                true -> {ok, Access, Secret, Token};
                false -> {error, <<"s3_credentials_unavailable">>}
            end
    end.

valid_optional_token(none) -> true;
valid_optional_token(Token) -> valid_credential(Token, 16384).

valid_credential(Value, Maximum) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Maximum
        andalso binary:match(Value, <<0>>) =:= nomatch.

valid_endpoint(Endpoint) when is_binary(Endpoint), byte_size(Endpoint) =< 4096 ->
    try uri_string:parse(Endpoint) of
        #{scheme := <<"https">>, host := Host} = Parsed when byte_size(Host) > 0 ->
            maps:get(userinfo, Parsed, undefined) =:= undefined
                andalso maps:get(query, Parsed, undefined) =:= undefined
                andalso maps:get(fragment, Parsed, undefined) =:= undefined
                andalso valid_endpoint_path(maps:get(path, Parsed, <<>>));
        _ -> false
    catch
        _:_ -> false
    end;
valid_endpoint(_) -> false.

valid_endpoint_path(<<>>) -> true;
valid_endpoint_path(<<"/">>) -> true;
valid_endpoint_path(_) -> false.

valid_bucket(Bucket) when is_binary(Bucket), byte_size(Bucket) >= 3,
                          byte_size(Bucket) =< 63 ->
    binary:match(Bucket, <<"..">>) =:= nomatch
        andalso valid_dns_chars(Bucket)
        andalso valid_dns_edge(Bucket);
valid_bucket(_) -> false.

valid_dns_chars(Bucket) ->
    lists:all(fun(Byte) ->
        (Byte >= $a andalso Byte =< $z)
            orelse (Byte >= $0 andalso Byte =< $9)
            orelse Byte =:= $-
            orelse Byte =:= $.
    end, binary_to_list(Bucket)).

valid_dns_edge(Bucket) ->
    First = binary:first(Bucket),
    Last = binary:last(Bucket),
    is_alnum(First) andalso is_alnum(Last).

is_alnum(Byte) ->
    (Byte >= $a andalso Byte =< $z) orelse (Byte >= $0 andalso Byte =< $9).

valid_region(Region) when is_binary(Region), byte_size(Region) > 0,
                          byte_size(Region) =< 64 ->
    lists:all(fun(Byte) -> is_alnum(Byte) orelse Byte =:= $- end,
              binary_to_list(Region));
valid_region(_) -> false.

valid_prefix(<<>>) -> true;
valid_prefix(Prefix) when is_binary(Prefix), byte_size(Prefix) =< 512 ->
    valid_key(Prefix) andalso not ends_with_slash(Prefix);
valid_prefix(_) -> false.

valid_key(Key) when is_binary(Key), byte_size(Key) > 0,
                    byte_size(Key) =< ?MAX_KEY_BYTES ->
    binary:match(Key, <<0>>) =:= nomatch
        andalso binary:match(Key, <<"\\">>) =:= nomatch
        andalso binary:match(Key, <<":">>) =:= nomatch
        andalso valid_segments(binary:split(Key, <<"/">>, [global]));
valid_key(_) -> false.

valid_segments([]) -> false;
valid_segments(Segments) ->
    lists:all(fun(Segment) ->
        Segment =/= <<>> andalso Segment =/= <<".">> andalso Segment =/= <<"..">>
    end, Segments).

ends_with_slash(Value) ->
    binary:last(Value) =:= $/.

join_prefix(<<>>, Key) -> Key;
join_prefix(Prefix, Key) -> <<Prefix/binary, "/", Key/binary>>.

trim_trailing_slash(Endpoint) ->
    case binary:last(Endpoint) of
        $/ -> binary:part(Endpoint, 0, byte_size(Endpoint) - 1);
        _ -> Endpoint
    end.

host_header(Parsed) ->
    Host = maps:get(host, Parsed),
    case maps:get(port, Parsed, undefined) of
        undefined -> Host;
        443 -> Host;
        Port -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>
    end.

uri_encode_key(Key) ->
    iolist_to_binary(lists:join(<<"/">>, [
        uri_encode(Segment) || Segment <- binary:split(Key, <<"/">>, [global])
    ])).

uri_encode(Value) ->
    iolist_to_binary([encode_byte(Byte) || <<Byte>> <= Value]).

encode_byte(Byte) when
        (Byte >= $A andalso Byte =< $Z)
        orelse (Byte >= $a andalso Byte =< $z)
        orelse (Byte >= $0 andalso Byte =< $9)
        orelse Byte =:= $-
        orelse Byte =:= $.
        orelse Byte =:= $_
        orelse Byte =:= $~ -> <<Byte>>;
encode_byte(Byte) -> <<"%", (upper_hex(Byte bsr 4)), (upper_hex(Byte band 16#0f))>>.

upper_hex(Value) when Value < 10 -> $0 + Value;
upper_hex(Value) -> $A + Value - 10.

normalize_header(Value) ->
    unicode:characters_to_binary(string:join(string:lexemes(binary_to_list(Value), " \t"), " ")).

lower(Value) -> unicode:characters_to_binary(string:lowercase(binary_to_list(Value))).

method_binary(get) -> <<"GET">>;
method_binary(put) -> <<"PUT">>;
method_binary(delete) -> <<"DELETE">>.

amz_date() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:system_time_to_universal_time(erlang:system_time(second), second),
    iolist_to_binary(io_lib:format(
        "~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ",
        [Year, Month, Day, Hour, Minute, Second]
    )).

hmac(Key, Value) -> crypto:mac(hmac, sha256, Key, Value).

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>>
        || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
