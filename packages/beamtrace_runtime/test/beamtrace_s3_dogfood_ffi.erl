%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_s3_dogfood_ffi).

-export([run/0]).

run() ->
    Endpoint = required_environment("BEAMTRACE_S3_DOGFOOD_ENDPOINT"),
    Config = {config, Endpoint, <<"beamtrace-dogfood">>, <<"us-east-1">>, <<"acceptance">>},
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

required_environment(Name) ->
    case os:getenv(Name) of
        false -> error({missing_environment, Name});
        Value -> unicode:characters_to_binary(Value)
    end.
