%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_mcp_stdio_ffi).

-export([read_line/0, write_line/1, write_error/1]).

read_line() ->
    case io:get_line(standard_io, "") of
        eof -> end_of_input;
        {error, Reason} -> {input_error, reason_binary(Reason)};
        Line when is_list(Line) -> {line, trim_newline(unicode:characters_to_binary(Line))};
        Line when is_binary(Line) -> {line, trim_newline(Line)}
    end.

write_line(Value) when is_binary(Value) ->
    ok = io:put_chars(standard_io, [Value, <<"\n">>]),
    nil.

write_error(Value) when is_binary(Value) ->
    ok = io:put_chars(standard_error, [Value, <<"\n">>]),
    nil.

trim_newline(Value) ->
    strip_trailing_byte(strip_trailing_byte(Value, $\n), $\r).

strip_trailing_byte(Value, Byte) when byte_size(Value) > 0 ->
    case binary:last(Value) of
        Byte -> binary:part(Value, 0, byte_size(Value) - 1);
        _ -> Value
    end;
strip_trailing_byte(Value, _Byte) -> Value.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
