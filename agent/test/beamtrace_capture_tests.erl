%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_capture_tests).
-include_lib("eunit/include/eunit.hrl").

collector_to_peer_round_trip_test_() ->
    {timeout, 60, fun collector_to_peer_round_trip/0}.

collector_captures_process_lifecycle_test_() ->
    {timeout, 60, fun collector_captures_process_lifecycle/0}.

collector_pushes_argument_filter_and_root_budget_to_target_test_() ->
    {timeout, 60, fun collector_pushes_argument_filter_and_root_budget_to_target/0}.

collector_preserves_a_compatible_preloaded_agent_test_() ->
    {timeout, 60, fun collector_preserves_a_compatible_preloaded_agent/0}.

collector_exposes_a_bounded_remote_arm_barrier_test_() ->
    {timeout, 60, fun collector_exposes_a_bounded_remote_arm_barrier/0}.

collector_replenishes_batch_credit_until_the_capture_is_drained_test_() ->
    {timeout, 60, fun collector_replenishes_batch_credit_until_the_capture_is_drained/0}.

collector_replenishes_batch_credit_until_the_capture_is_drained() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {ok, Peer, Node} = beamtrace_test_peer:start("ag_credit_drain_", Cookie),
    try
        ok = load_fixture(Node),
        ok = erpc:call(Node, beamtrace_agent_fixture, schedule_burst, [600]),
        {ok, {Events, <<"complete">>}} = beamtrace_capture_ffi:collect_remote(
            atom_to_binary(Node, utf8),
            Cookie,
            <<"beamtrace_agent_fixture">>,
            <<"trigger_burst">>,
            1,
            5000,
            5000,
            100000000,
            10000
        ),
        ?assert(length(Events) > 1024),
        ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, [])),
        ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent]))
    after
        try peer:stop(Peer)
        catch
            exit:noproc -> ok
        end
    end.

collector_exposes_a_bounded_remote_arm_barrier() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {ok, Peer, Node} = beamtrace_test_peer:start("ag_arm_barrier_", Cookie),
    try
        ok = load_fixture(Node),
        Target = erpc:call(Node, beamtrace_agent_fixture, start_echo, []),
        Parent = self(),
        _Collector = spawn(fun() ->
            Parent ! {capture_result, beamtrace_capture_ffi:collect_remote(
                atom_to_binary(Node, utf8),
                Cookie,
                <<"beamtrace_agent_fixture">>,
                <<"trigger">>,
                1,
                3000,
                10000,
                10000000,
                10000
            )}
        end),
        ?assertEqual(
            {ok, nil},
            beamtrace_capture_ffi:wait_remote_armed(
                atom_to_binary(Node, utf8), Cookie, 2000
            )
        ),
        ok = erpc:call(Node, beamtrace_agent_fixture, trigger, [Target]),
        receive
            {capture_result, {ok, {Events, <<"complete">>}}} ->
                ?assert(lists:any(fun is_root_event/1, Events))
        after 5000 ->
            error(capture_result_timeout)
        end,
        ok = erpc:call(Node, beamtrace_agent_fixture, stop_echo, [Target]),
        ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, [])),
        ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent]))
    after
        try peer:stop(Peer)
        catch
            exit:noproc -> ok
        end
    end.

is_root_event({raw_event_with_term, _Id, _Root, _EventNode, _Pid, _At,
        <<"root">>, _PeerNode, _PeerPid, _Serial, _Semantic, _Metadata,
        _Term}) -> true;
is_root_event(_) -> false.

collector_preserves_a_compatible_preloaded_agent() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {ok, Peer, Node} = beamtrace_test_peer:start("ag_preloaded_", Cookie),
    try
        ok = load_fixture(Node),
        {ok, loaded, Digest} = beamtrace_relay:inject(Node),
        ok = erpc:call(Node, beamtrace_agent_fixture, schedule_filtered, []),
        {ok, {_Events, <<"complete">>}} = beamtrace_capture_ffi:collect_remote_spec(
            atom_to_binary(Node, utf8),
            Cookie,
            <<"beamtrace_agent_fixture">>,
            <<"filtered_trigger">>,
            1,
            3000,
            10000,
            10000000,
            10000,
            1,
            {agent_arg_tag, 0, agent_equal, <<"allowed">>},
            metadata,
            generic
        ),
        ?assertMatch({_Filename, _}, erpc:call(Node, code, is_loaded, [beamtrace_agent])),
        ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, [])),
        ok = beamtrace_relay:unload_unstarted(Node, Digest)
    after
        try peer:stop(Peer)
        catch
            exit:noproc -> ok
        end
    end.

collector_pushes_argument_filter_and_root_budget_to_target() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {ok, Peer, Node} = beamtrace_test_peer:start("ag_filter_", Cookie),
    try
        ok = load_fixture(Node),
        ok = erpc:call(Node, beamtrace_agent_fixture, schedule_filtered, []),
        {ok, {Events, <<"complete">>}} = beamtrace_capture_ffi:collect_remote_spec(
            atom_to_binary(Node, utf8),
            Cookie,
            <<"beamtrace_agent_fixture">>,
            <<"filtered_trigger">>,
            1,
            3000,
            10000,
            10000000,
            10000,
            1,
            {agent_arg_tag, 0, agent_equal, <<"allowed">>},
            metadata,
            generic
        ),
        Roots = [Event ||
            {raw_event_with_term, _Id, _Root, _EventNode, _Pid, _At,
                <<"root">>, _PeerNode, _PeerPid, _Serial, _Semantic,
                _Metadata, _Term} = Event <- Events],
        ?assertEqual(1, length(Roots)),
        ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, [])),
        ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent]))
    after
        try peer:stop(Peer)
        catch
            exit:noproc -> ok
        end
    end.

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
            {raw_event_with_term, _Id, _Root, _EventNode, _Pid, _At, Kind,
                _PeerNode, _PeerPid, _Serial, _Semantic, _Metadata, _Term} <- Events],
        ?assert(lists:member(<<"root">>, Kinds)),
        ?assert(lists:member(<<"send">>, Kinds)),
        ?assert(lists:member(<<"receive">>, Kinds)),
        assert_one_monotonic_clock_domain(Events),
        SendTerms = [Term ||
            {raw_event_with_term, _Id2, _Root2, _EventNode2, _Pid2, _At2,
                <<"send">>, _PeerNode2, _PeerPid2, _Serial2, _Semantic2,
                _Metadata2, Term} <- Events],
        ?assert(lists:any(fun
            ({raw_tuple, 2, [{raw_atom, <<"work">>},
                {raw_scalar, <<"pid">>, <<>>, Fingerprint}]}) ->
                byte_size(Fingerprint) =:= 64;
            (_) -> false
        end, SendTerms)),
        ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, [])),
        ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent])),
        ok = erpc:call(Node, beamtrace_agent_fixture, stop_echo, [Target])
    after
        try peer:stop(Peer)
        catch
            exit:noproc -> ok
        end
    end.

assert_one_monotonic_clock_domain(Events) ->
    Timed = [{Kind, At} ||
        {raw_event_with_term, _Id, _Root, _EventNode, _Pid, At, Kind,
            _PeerNode, _PeerPid, _Serial, _Semantic, _Metadata, _Term} <- Events,
        Kind =:= <<"root">> orelse Kind =:= <<"send">> orelse
            Kind =:= <<"receive">>],
    [RootAt] = [At || {<<"root">>, At} <- Timed],
    ?assert(is_integer(RootAt)),
    ?assert(lists:all(fun({_Kind, At}) ->
        is_integer(At) andalso At >= RootAt andalso
            At - RootAt =< 5_000_000_000
    end, Timed)),
    ok.

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
            {raw_event_with_term, _Id, _Root, _EventNode, _Pid, _At, Kind,
                _PeerNode, _PeerPid, _Serial, _Semantic, _Metadata, _Term} <- Events],
        ?assert(lists:member(<<"root">>, Kinds)),
        ?assert(lists:member(<<"spawn">>, Kinds)),
        ?assert(lists:member(<<"link">>, Kinds)),
        ?assert(lists:member(<<"register">>, Kinds)),
        ?assert(lists:member(<<"exit">>, Kinds)),
        RegisteredMetadata = [Metadata ||
            {raw_event_with_term, _Id, _Root, _EventNode, _Pid, _At,
                <<"register">>, _PeerNode, _PeerPid, _Serial,
                <<"beamtrace_lifecycle_child">>, Metadata, _Term} <- Events],
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
