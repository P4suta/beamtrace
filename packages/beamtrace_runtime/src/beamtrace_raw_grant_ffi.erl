%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_raw_grant_ffi).

-export([new_token/0, sha256_hex/1, valid_token/1]).

new_token() ->
    base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).

sha256_hex(Value) when is_binary(Value) ->
    hex(crypto:hash(sha256, Value)).

valid_token(Token) when is_binary(Token), byte_size(Token) =:= 43 ->
    try base64:decode(Token, #{mode => urlsafe, padding => false}) of
        Bytes -> byte_size(Bytes) =:= 32
    catch
        _:_ -> false
    end;
valid_token(_) -> false.

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>>
        || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
