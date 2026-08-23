%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_id_token_ffi).

-include_lib("public_key/include/public_key.hrl").

-export([parts/1, verify_rs256/3]).

-define(MAX_TOKEN_BYTES, 65536).
-define(MAX_HEADER_BYTES, 4096).
-define(MAX_PAYLOAD_BYTES, 32768).

parts(Token) when is_binary(Token), byte_size(Token) =< ?MAX_TOKEN_BYTES ->
    case binary:split(Token, <<".">>, [global]) of
        [HeaderPart, PayloadPart, SignaturePart]
                when byte_size(HeaderPart) > 0, byte_size(PayloadPart) > 0,
                     byte_size(SignaturePart) > 0 ->
            case {
                decode_segment(HeaderPart, ?MAX_HEADER_BYTES),
                decode_segment(PayloadPart, ?MAX_PAYLOAD_BYTES),
                valid_segment(SignaturePart)
            } of
                {{ok, Header}, {ok, Payload}, true} -> {ok, {Header, Payload}};
                _ -> {error, <<"malformed">>}
            end;
        _ -> {error, <<"malformed">>}
    end;
parts(_Token) ->
    {error, <<"malformed">>}.

verify_rs256(Token, ModulusEncoded, ExponentEncoded)
        when is_binary(Token), is_binary(ModulusEncoded), is_binary(ExponentEncoded) ->
    try
        [HeaderPart, PayloadPart, SignaturePart] = binary:split(Token, <<".">>, [global]),
        {ok, Signature} = decode_segment(SignaturePart, 1024),
        {ok, ModulusBytes} = decode_segment(ModulusEncoded, 1024),
        {ok, ExponentBytes} = decode_segment(ExponentEncoded, 8),
        ModulusSize = byte_size(ModulusBytes),
        Modulus = binary:decode_unsigned(ModulusBytes),
        Exponent = binary:decode_unsigned(ExponentBytes),
        true = ModulusSize >= 256 andalso ModulusSize =< 1024,
        true = byte_size(Signature) =:= ModulusSize,
        true = Exponent >= 3 andalso Exponent =< 16#ffffffff andalso Exponent rem 2 =:= 1,
        Key = #'RSAPublicKey'{modulus = Modulus, publicExponent = Exponent},
        SigningInput = <<HeaderPart/binary, ".", PayloadPart/binary>>,
        public_key:verify(SigningInput, sha256, Signature, Key)
    catch
        _:_ -> false
    end.

decode_segment(Segment, MaxBytes) ->
    case valid_segment(Segment) of
        false -> {error, invalid_base64url};
        true ->
            try
                Standard0 = binary:replace(Segment, <<"-">>, <<"+">>, [global]),
                Standard = binary:replace(Standard0, <<"_">>, <<"/">>, [global]),
                Padding = case byte_size(Standard) rem 4 of
                    0 -> <<>>;
                    2 -> <<"==">>;
                    3 -> <<"=">>;
                    _ -> error(invalid_base64url)
                end,
                Decoded = base64:decode(<<Standard/binary, Padding/binary>>),
                case byte_size(Decoded) =< MaxBytes of
                    true -> {ok, Decoded};
                    false -> {error, too_large}
                end
            catch
                _:_ -> {error, invalid_base64url}
            end
    end.

valid_segment(<<>>) -> false;
valid_segment(Segment) ->
    lists:all(fun valid_base64url_byte/1, binary_to_list(Segment)).

valid_base64url_byte(Byte) ->
    (Byte >= $a andalso Byte =< $z) orelse
    (Byte >= $A andalso Byte =< $Z) orelse
    (Byte >= $0 andalso Byte =< $9) orelse
    Byte =:= $- orelse Byte =:= $_.
