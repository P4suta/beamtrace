%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_distributed_tests).
-include_lib("eunit/include/eunit.hrl").

two_node_partial_order_capture_test_() ->
    {timeout, 60, fun two_node_partial_order_capture/0}.

two_node_partial_order_capture() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {PeerA, NodeA} = start_peer("ag_dist_a_", Cookie),
    {PeerB, NodeB} = start_peer("ag_dist_b_", Cookie),
    try
        ok = load_fixture(NodeA),
        ok = load_fixture(NodeB),
        Target = erpc:call(NodeB, beamtrace_agent_fixture, start_echo, []),
        ok = erpc:call(
            NodeA,
            beamtrace_agent_fixture,
            schedule_trigger,
            [Target]
        ),
        Events = verified_events(
            beamtrace_capture_ffi:collect_distributed(
                [atom_to_binary(NodeA, utf8), atom_to_binary(NodeB, utf8)],
                Cookie,
                <<"beamtrace_agent_fixture">>,
                <<"trigger">>,
                1,
                5000,
                10000,
                10000000,
                10000
            )),
        EventNodes = lists:usort([EventNode ||
            {raw_event_v2, _Id, _Root, EventNode, _Pid, _At, _Order, _Kind,
                _PeerNode, _PeerPid, _Previous, _Current, _Semantic, _Metadata,
                _Term} <- Events]),
        ?assertEqual(
            lists:sort([atom_to_binary(NodeA, utf8), atom_to_binary(NodeB, utf8)]),
            lists:sort(EventNodes)
        ),
        Kinds = [Kind ||
            {raw_event_v2, _Id, _Root, _EventNode, _Pid, _At, _Order, Kind,
                _PeerNode, _PeerPid, _Previous, _Current, _Semantic, _Metadata,
                _Term} <- Events],
        ?assert(lists:member(<<"root">>, Kinds)),
        ?assert(lists:member(<<"send">>, Kinds)),
        ?assert(lists:member(<<"receive">>, Kinds)),
        assert_clean(NodeA),
        assert_clean(NodeB),
        ok = erpc:call(NodeB, beamtrace_agent_fixture, stop_echo, [Target])
    after
        stop_peer(PeerA),
        stop_peer(PeerB)
    end.

verified_events({ok, {Events,
        {raw_outcome, EndKind, _EndDetail, [], Receipts},
        {clock_calibration, Anchor, Clocks}}}) ->
    ?assert(lists:member(EndKind, [<<"quiet_period">>, <<"time_window">>])),
    ?assertEqual(2, length(Receipts)),
    ?assertEqual(2, length(Clocks)),
    ?assert(is_integer(Anchor)),
    Events;
verified_events(Other) ->
    error({capture_was_not_delivery_verified, Other}).

start_peer(Prefix, Cookie) ->
    {ok, Peer, Node} = beamtrace_test_peer:start(Prefix, Cookie),
    {Peer, Node}.

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

assert_clean(Node) ->
    ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, [])),
    ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent])).

stop_peer(Peer) ->
    try peer:stop(Peer)
    catch
        exit:noproc -> ok
    end.
