%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_audit_ffi).

-export([sha256_hex/1]).

sha256_hex(Value) when is_binary(Value) ->
    Digest = crypto:hash(sha256, Value),
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>> || <<Byte>> <= Digest >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
