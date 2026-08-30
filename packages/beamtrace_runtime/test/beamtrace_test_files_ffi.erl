%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_test_files_ffi).
-export([read/1]).

read(Path) when is_binary(Path) ->
    case file:read_file(Path) of
        {ok, Content} -> {ok, Content};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.
