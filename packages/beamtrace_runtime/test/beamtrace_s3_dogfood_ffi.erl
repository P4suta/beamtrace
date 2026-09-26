%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_s3_dogfood_ffi).

-export([run/0]).

run() ->
    Endpoint = required_environment("BEAMTRACE_S3_DOGFOOD_ENDPOINT"),
    Bucket = <<"beamtrace-dogfood">>,
    Region = <<"us-east-1">>,
    ok = create_bucket(Endpoint, Bucket, Region),
    Config = {config, Endpoint, Bucket, Region, <<"acceptance">>},
    Key = <<"segments/round trip+percent%.ndjson">>,
    Payload = <<"{\"sentinel\":\"s3-round-trip\",\"events\":1}\n">>,
    Different = <<"{\"sentinel\":\"must-not-overwrite\"}\n">>,
    {ok, nil} = beamtrace_s3_blob_ffi:delete(Config, Key),
    {ok, {Key, Digest, Bytes, true}} = beamtrace_s3_blob_ffi:put(Config, Key, Payload),
    true = byte_size(Digest) =:= 64,
    true = Bytes =:= byte_size(Payload),
    {ok, Payload} = beamtrace_s3_blob_ffi:read(Config, Key),
    {ok, {Key, Digest, Bytes, false}} = beamtrace_s3_blob_ffi:put(Config, Key, Payload),
    {error, <<"blob_conflict">>} = beamtrace_s3_blob_ffi:put(Config, Key, Different),
    {ok, nil} = beamtrace_s3_blob_ffi:delete(Config, Key),
    {ok, nil} = beamtrace_s3_blob_ffi:delete(Config, Key),
    {error, <<"blob_not_found">>} = beamtrace_s3_blob_ffi:read(Config, Key),
    io:format("S3-compatible TLS round trip passed.~n"),
    ok.

%% The blob store never creates buckets, so the acceptance run makes its own with one CreateBucket request.
%% The blob store's SigV4 code signs it and the peer is verified against the same CA bundle, so the setup crosses the same signing and TLS boundary as the round trip.
create_bucket(Endpoint, Bucket, Region) ->
    #{host := Host, port := Port} = uri_string:parse(Endpoint),
    HostHeader = <<Host/binary, ":", (integer_to_binary(Port))/binary>>,
    CanonicalUri = <<"/", Bucket/binary>>,
    AmzDate = amz_date(),
    Authorization = beamtrace_s3_blob_ffi:authorization_for_test(
        <<"PUT">>,
        CanonicalUri,
        HostHeader,
        Region,
        required_environment("AWS_ACCESS_KEY_ID"),
        required_environment("AWS_SECRET_ACCESS_KEY"),
        AmzDate,
        [],
        <<>>
    ),
    Headers = [
        {"authorization", binary_to_list(Authorization)},
        {"host", binary_to_list(HostHeader)},
        {"x-amz-content-sha256", binary_to_list(binary:encode_hex(crypto:hash(sha256, <<>>), lowercase))},
        {"x-amz-date", binary_to_list(AmzDate)}
    ],
    SslOptions = [
        {verify, verify_peer},
        {cacertfile, binary_to_list(required_environment("AWS_CA_BUNDLE"))},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ],
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(inets),
    Url = binary_to_list(<<Endpoint/binary, CanonicalUri/binary>>),
    Request = {Url, Headers, "application/octet-stream", <<>>},
    case httpc:request(put, Request, [{timeout, 15000}, {ssl, SslOptions}], [{body_format, binary}]) of
        {ok, {{_Version, 200, _Reason}, _ResponseHeaders, _Body}} -> ok;
        Other -> error({create_bucket_failed, Other})
    end.

amz_date() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:system_time_to_universal_time(erlang:system_time(second), second),
    iolist_to_binary(io_lib:format(
        "~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ",
        [Year, Month, Day, Hour, Minute, Second]
    )).

required_environment(Name) ->
    case os:getenv(Name) of
        false -> error({missing_environment, Name});
        Value -> unicode:characters_to_binary(Value)
    end.
