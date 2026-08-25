%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_export_ffi).

-export([unix_time_nanoseconds/0]).

-spec unix_time_nanoseconds() -> non_neg_integer().
unix_time_nanoseconds() ->
    erlang:system_time(nanosecond).
