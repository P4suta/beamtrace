%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_test_peer).

-export([start/2]).

start(Prefix, Cookie) ->
    Name = list_to_atom(Prefix ++ integer_to_list(erlang:unique_integer([positive]))),
    Base = #{
        name => Name,
        args => ["-setcookie", binary_to_list(Cookie)]
    },
    Options = case net_kernel:longnames() of
        true -> Base#{longnames => true, host => "127.0.0.1"};
        false -> Base#{longnames => false}
    end,
    peer:start_link(Options).
