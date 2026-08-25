%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_raw_grant_ffi).

-export([valid_token/1]).

valid_token(Token) when is_binary(Token), byte_size(Token) =:= 43 ->
    try base64:decode(Token, #{mode => urlsafe, padding => false}) of
        Bytes -> byte_size(Bytes) =:= 32
    catch
        _:_ -> false
    end;
valid_token(_) -> false.
