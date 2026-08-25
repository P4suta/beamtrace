%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_relay_session_ffi).
-export([new_id/0]).

new_id() ->
    'beamtrace_runtime@crypto':random_hex(16).
