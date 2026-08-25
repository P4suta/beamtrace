%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_format_fixture_ffi).
-export([read/1]).

read(Relative) when is_binary(Relative) ->
    case binary:match(Relative, <<"..">>) =:= nomatch
         andalso binary:match(Relative, <<"\\">>) =:= nomatch of
        true ->
            Path = filename:join([
                "..", "..", "fixtures", "format-v2",
                unicode:characters_to_list(Relative)
            ]),
            case file:read_file(Path) of
                {ok, Source} -> {ok, Source};
                {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
            end;
        false -> {error, <<"invalid_fixture_path">>}
    end;
read(_Relative) -> {error, <<"invalid_fixture_path">>}.
