%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_id_token_test_ffi).

-include_lib("public_key/include/public_key.hrl").

-export([fixture/5, new_signer/0, sign/6, jwks/1]).

fixture(Algorithm, Issuer, Audience, Nonce, NowSeconds) ->
    Signer = new_signer(),
    {fixture,
     sign(Signer, Algorithm, Issuer, Audience, Nonce, NowSeconds),
     jwks(Signer)}.

new_signer() ->
    Private = public_key:generate_key({rsa, 2048, 65537}),
    {signer, Private}.

sign({signer, Private}, Algorithm, Issuer, Audience, Nonce, NowSeconds) ->
    Header = iolist_to_binary([
        <<"{\"alg\":\"">>, Algorithm,
        <<"\",\"typ\":\"JWT\",\"kid\":\"key-1\"}">>
    ]),
    Payload = iolist_to_binary([
        <<"{\"iss\":\"">>, Issuer,
        <<"\",\"aud\":\"">>, Audience,
        <<"\",\"sub\":\"user-1\",\"nonce\":\"">>, Nonce,
        <<"\",\"exp\":">>, integer_to_binary(NowSeconds + 300),
        <<",\"iat\":">>, integer_to_binary(NowSeconds - 10),
        <<",\"nbf\":">>, integer_to_binary(NowSeconds - 10),
        <<",\"groups\":[\"beamtrace-investigators\"]}">>
    ]),
    HeaderPart = base64url(Header),
    PayloadPart = base64url(Payload),
    SigningInput = <<HeaderPart/binary, ".", PayloadPart/binary>>,
    Signature = public_key:sign(SigningInput, sha256, Private),
    <<SigningInput/binary, ".", (base64url(Signature))/binary>>.

jwks({signer, Private}) ->
    Modulus = Private#'RSAPrivateKey'.modulus,
    Exponent = Private#'RSAPrivateKey'.publicExponent,
    iolist_to_binary([
        <<"{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"key-1\",">>,
        <<"\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"">>,
        base64url(binary:encode_unsigned(Modulus)),
        <<"\",\"e\":\"">>,
        base64url(binary:encode_unsigned(Exponent)),
        <<"\"}]} ">>
    ]).

base64url(Binary) ->
    Encoded = base64:encode(Binary),
    NoPadding = binary:replace(Encoded, <<"=">>, <<>>, [global]),
    WithDash = binary:replace(NoPadding, <<"+">>, <<"-">>, [global]),
    binary:replace(WithDash, <<"/">>, <<"_">>, [global]).
