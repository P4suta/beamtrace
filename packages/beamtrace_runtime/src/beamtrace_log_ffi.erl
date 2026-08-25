%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_log_ffi).
-export([format/0]).

format() ->
    case os:getenv("BEAMTRACE_LOG_FORMAT") of
        "json" -> <<"json">>;
        _ -> <<"human">>
    end.
