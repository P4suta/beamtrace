%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_audit_store_tests).

-include_lib("eunit/include/eunit.hrl").

concurrent_appends_form_one_valid_chain_test_() ->
    {timeout, 10, fun concurrent_appends_form_one_valid_chain/0}.

concurrent_appends_form_one_valid_chain() ->
    Store = beamtrace_audit_store_ffi:new(),
    Parent = self(),
    Count = 40,
    [spawn(fun() ->
        nil = beamtrace_audit_store_ffi:append(
            Store,
            1000 + Index,
            <<"investigator">>,
            <<"annotation.create">>,
            <<"event:one">>,
            <<"allowed">>
        ),
        Parent ! {appended, Index}
    end) || Index <- lists:seq(1, Count)],
    [receive {appended, Index} -> ok after 5000 -> error(append_timeout) end
        || Index <- lists:seq(1, Count)],
    Log = beamtrace_audit_store_ffi:snapshot(Store),
    {audit_log, Entries, _Head} = Log,
    ?assertEqual(Count, length(Entries)),
    ?assertEqual({ok, nil}, 'beamtrace_runtime@audit':verify(Log)),
    nil = beamtrace_audit_store_ffi:close(Store).

owner_death_stops_audit_store_test() ->
    Parent = self(),
    Owner = spawn(fun() ->
        Store = beamtrace_audit_store_ffi:new(),
        Parent ! {audit_store, Store}
    end),
    Store = receive {audit_store, Pid} -> Pid after 1000 -> error(no_store) end,
    OwnerMonitor = erlang:monitor(process, Owner),
    receive {'DOWN', OwnerMonitor, process, Owner, _} -> ok after 1000 -> error(owner_alive) end,
    StoreMonitor = erlang:monitor(process, Store),
    receive
        {'DOWN', StoreMonitor, process, Store, _} -> ok
    after 1000 ->
        error(audit_store_leaked)
    end.
