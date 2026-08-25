#!/usr/bin/env escript
%%! -noshell
%% SPDX-License-Identifier: Apache-2.0 OR MIT

main([Root]) ->
    ok = code:add_pathsa(filelib:wildcard(filename:join([
        Root, "packages", "beamtrace_core", "build", "dev", "erlang", "*", "ebin"
    ]))),
    Base = filename:join([Root, "fixtures", "format-v2"]),
    Valid = [
        {"valid/manifest.json", decode_manifest},
        {"valid/event.json", decode_event},
        {"valid/inferred-event.json", decode_event},
        {"valid/graph-segment.json", decode_graph_segment},
        {"valid/clocks.json", decode_clocks}
    ],
    Invalid = [
        {"invalid/event-unknown-field.json", decode_event},
        {"invalid/event-confidence.json", decode_event},
        {"invalid/event-unsafe-time.json", decode_event},
        {"invalid/event-partial-serial.json", decode_event},
        {"invalid/event-noncanonical.json", decode_event},
        {"invalid/manifest-unknown-version.json", decode_manifest},
        {"invalid/clocks-invalid-rtt.json", decode_clocks}
    ],
    lists:foreach(fun({Path, Decoder}) ->
        expect(ok, Base, Path, Decoder)
    end, Valid),
    lists:foreach(fun({Path, Decoder}) ->
        expect(error, Base, Path, Decoder)
    end, Invalid),
    io:format("Codec golden corpus passed (~B valid, ~B invalid).~n", [
        length(Valid), length(Invalid)
    ]),
    ok;
main(_) ->
    io:format(standard_error, "usage: format-conformance.escript REPOSITORY_ROOT~n", []),
    halt(2).

expect(Expected, Base, Relative, Decoder) ->
    Path = filename:join(Base, Relative),
    {ok, Source0} = file:read_file(Path),
    Source = string:trim(Source0),
    Result = apply('beamtrace@codec', Decoder, [Source]),
    Actual = case Result of
        {ok, _} -> ok;
        {error, _} -> error
    end,
    case Actual =:= Expected of
        true -> ok;
        false ->
            io:format(standard_error, "unexpected ~p result for ~s: ~p~n", [
                Actual, Relative, Result
            ]),
            halt(1)
    end.
