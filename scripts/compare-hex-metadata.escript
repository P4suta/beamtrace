#!/usr/bin/env escript
%%! -noshell
%% SPDX-License-Identifier: Apache-2.0 OR MIT
-mode(compile).

main([ExpectedPath, ActualPath]) ->
    case {read_metadata(ExpectedPath), read_metadata(ActualPath)} of
        {{ok, Expected}, {ok, Actual}} ->
            case normalize(Expected) =:= normalize(Actual) of
                true ->
                    halt(0);
                false ->
                    io:format(standard_error, "Hex metadata values differ.~n", []),
                    halt(1)
            end;
        {{error, Reason}, _} ->
            report_read_error(ExpectedPath, Reason);
        {_, {error, Reason}} ->
            report_read_error(ActualPath, Reason)
    end;
main(_) ->
    io:format(
        standard_error,
        "Usage: compare-hex-metadata.escript EXPECTED ACTUAL~n",
        []
    ),
    halt(64).

read_metadata(Path) ->
    file:consult(Path).

report_read_error(Path, Reason) ->
    io:format(standard_error, "Could not parse Hex metadata ~ts: ~tp~n", [Path, Reason]),
    halt(2).

normalize(Value) when is_list(Value) ->
    case io_lib:printable_unicode_list(Value) of
        true ->
            Value;
        false ->
            lists:sort([normalize(Item) || Item <- Value])
    end;
normalize(Value) when is_tuple(Value) ->
    list_to_tuple([normalize(Item) || Item <- tuple_to_list(Value)]);
normalize(Value) when is_map(Value) ->
    maps:map(fun(_Key, Item) -> normalize(Item) end, Value);
normalize(Value) ->
    Value.
