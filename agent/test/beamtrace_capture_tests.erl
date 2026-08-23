%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_capture_tests).
-include_lib("eunit/include/eunit.hrl").

collector_to_peer_round_trip_test_() ->
    {timeout, 60, fun collector_to_peer_round_trip/0}.

collector_captures_process_lifecycle_test_() ->
    {timeout, 60, fun collector_captures_process_lifecycle/0}.

collector_to_peer_round_trip() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {ok, Peer, Node} = beamtrace_test_peer:start("ag_capture_", Cookie),
    try
        ok = load_fixture(Node),
        Target = erpc:call(Node, beamtrace_agent_fixture, start_echo, []),
        ok = erpc:call(
            Node,
            beamtrace_agent_fixture,
            schedule_trigger,
            [Target]
        ),
        CaptureResult = beamtrace_capture_ffi:collect_remote(
            atom_to_binary(Node, utf8),
            Cookie,
            <<"beamtrace_agent_fixture">>,
            <<"trigger">>,
            1,
            3000,
            10000,
            10000000,
            10000
        ),
        {ok, {Events, <<"complete">>}} = CaptureResult,
        Kinds = [Kind ||
            {raw_event_with_metadata, _Id, _Root, _EventNode, _Pid, _At, Kind,
                _PeerNode, _PeerPid, _Serial, _Semantic, _Metadata} <- Events],
        ?assert(lists:member(<<"root">>, Kinds)),
        ?assert(lists:member(<<"send">>, Kinds)),
        ?assert(lists:member(<<"receive">>, Kinds)),
        ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, [])),
        ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent])),
        ok = erpc:call(Node, beamtrace_agent_fixture, stop_echo, [Target])
    after
        try peer:stop(Peer)
        catch
            exit:noproc -> ok
        end
    end.

collector_captures_process_lifecycle() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {ok, Peer, Node} = beamtrace_test_peer:start("ag_lifecycle_", Cookie),
    try
        ok = load_fixture(Node),
        ok = erpc:call(Node, beamtrace_agent_fixture, schedule_lifecycle, []),
        {ok, {Events, <<"complete">>}} = beamtrace_capture_ffi:collect_remote(
            atom_to_binary(Node, utf8),
            Cookie,
            <<"beamtrace_agent_fixture">>,
            <<"trigger_lifecycle">>,
            0,
            3000,
            10000,
            10000000,
            10000
        ),
        Kinds = [Kind ||
            {raw_event_with_metadata, _Id, _Root, _EventNode, _Pid, _At, Kind,
                _PeerNode, _PeerPid, _Serial, _Semantic, _Metadata} <- Events],
        ?assert(lists:member(<<"root">>, Kinds)),
        ?assert(lists:member(<<"spawn">>, Kinds)),
        ?assert(lists:member(<<"link">>, Kinds)),
        ?assert(lists:member(<<"register">>, Kinds)),
        ?assert(lists:member(<<"exit">>, Kinds)),
        RegisteredMetadata = [Metadata ||
            {raw_event_with_metadata, _Id, _Root, _EventNode, _Pid, _At,
                <<"register">>, _PeerNode, _PeerPid, _Serial,
                <<"beamtrace_lifecycle_child">>, Metadata} <- Events],
        ?assertMatch(
            [{raw_process_metadata, <<"beamtrace_lifecycle_child">>,
                _ProcessLabel, _Module, _Function, _Arity,
                _Ancestors, _ChildId}],
            RegisteredMetadata
        ),
        ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, [])),
        ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent]))
    after
        try peer:stop(Peer)
        catch
            exit:noproc -> ok
        end
    end.

load_fixture(Node) ->
    {beamtrace_agent_fixture, Beam, Filename} =
        code:get_object_code(beamtrace_agent_fixture),
    case erpc:call(
        Node,
        code,
        load_binary,
        [beamtrace_agent_fixture, Filename, Beam]
    ) of
        {module, beamtrace_agent_fixture} -> ok;
        Other -> {error, Other}
    end.
