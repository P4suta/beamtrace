%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_relay_tests).
-include_lib("eunit/include/eunit.hrl").

configured_agent_binary_test() ->
    {beamtrace_agent, ExpectedBeam, Filename} =
        code:get_object_code(beamtrace_agent),
    with_agent_beam_env(Filename, fun() ->
        {ok, ExpectedBeam, Filename, Digest} = beamtrace_relay:agent_binary(),
        ?assertEqual(crypto:hash(sha256, ExpectedBeam), Digest)
    end).

configured_agent_binary_rejects_wrong_module_test() ->
    {beamtrace_test_peer, _Beam, Filename} =
        code:get_object_code(beamtrace_test_peer),
    with_agent_beam_env(Filename, fun() ->
        ?assertEqual(
            {error, {invalid_agent_beam, {wrong_module, beamtrace_test_peer}}},
            beamtrace_relay:agent_binary()
        )
    end).

injection_lifecycle_test_() ->
    {timeout, 45, fun injection_lifecycle/0}.

injection_lifecycle() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {ok, Peer, Node} = beamtrace_test_peer:start("ag_target_", Cookie),
    try
        #{node := Node, otp_release := OtpRelease, arbitrary_rpc := false} =
            beamtrace_relay:probe(Node),
        ?assert(is_binary(OtpRelease)),
        {ok, Samples, NextOffset} = beamtrace_relay:sample_processes(Node, 0, 5),
        ?assert(length(Samples) =< 5),
        ?assert(is_integer(NextOffset)),
        ?assert(lists:all(fun(Sample) ->
            maps:is_key(pid, Sample)
                andalso maps:is_key(message_queue_len, Sample)
                andalso maps:is_key(memory, Sample)
                andalso maps:is_key(reductions, Sample)
                andalso not maps:is_key(messages, Sample)
        end, Samples)),
        {ok, loaded, Digest} = beamtrace_relay:inject(Node),
        ?assertEqual(32, byte_size(Digest)),
        {ok, reused, Digest} = beamtrace_relay:inject(Node),
        ok = beamtrace_relay:unload_unstarted(Node, Digest),
        ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent])),
        {ok, loaded, Digest} = beamtrace_relay:inject(Node),

        {ok, Agent} = beamtrace_relay:start_agent(Node, self(), #{capture_id => <<"peer">>}),
        ?assertEqual(
            {error, {agent_active, Agent}},
            beamtrace_relay:unload(Node, Digest, Agent)
        ),
        ok = beamtrace_relay:stop_agent(Node, Agent),
        ok = beamtrace_relay:unload(Node, Digest, Agent),
        ?assertEqual(false, erpc:call(Node, code, is_loaded, [beamtrace_agent])),

        ConflictBeam = conflicting_agent_beam(),
        {module, beamtrace_agent} = erpc:call(
            Node,
            code,
            load_binary,
            [beamtrace_agent, "conflict.beam", ConflictBeam]
        ),
        ?assertMatch(
            {error, {agent_conflict, _ExistingDigest}},
            beamtrace_relay:inject(Node)
        ),
        ?assertEqual(conflict, erpc:call(Node, beamtrace_agent, version, [])),
        _ = erpc:call(Node, code, purge, [beamtrace_agent]),
        true = erpc:call(Node, code, delete, [beamtrace_agent]),
        _ = erpc:call(Node, code, purge, [beamtrace_agent]),

        {ok, loaded, _} = beamtrace_relay:inject(Node),
        ok = load_fixture(Node),
        {ok, Candidates} = beamtrace_relay:search_mfas(
            Node,
            <<"agent_fixture:tri">>,
            20
        ),
        ?assert(lists:member(
            #{
                module => <<"beamtrace_agent_fixture">>,
                function => <<"trigger">>,
                arity => 1
            },
            Candidates
        )),
        ?assert(length(Candidates) =< 20),
        relay_death_cleans_exact_trace(Node),
        ?assertEqual(false, erpc:call(Node, seq_trace, get_system_tracer, []))
    after
        peer:stop(Peer)
    end.

relay_death_cleans_exact_trace(Node) ->
    Parent = self(),
    Relay = spawn(fun() ->
        {ok, Agent} = beamtrace_relay:start_agent(
            Node,
            self(),
            #{capture_id => <<"relay-death">>, max_duration_ms => 10000}
        ),
        {ok, armed} = beamtrace_relay:arm_agent(
            Node,
            Agent,
            {beamtrace_agent_fixture, trigger, 1}
        ),
        Parent ! {armed_by_relay, self(), Agent},
        receive stop -> ok end
    end),
    Agent = receive
        {armed_by_relay, Relay, Pid} -> Pid
    after 5000 ->
        error(relay_did_not_arm)
    end,
    ?assertEqual(Agent, erpc:call(Node, seq_trace, get_system_tracer, [])),
    exit(Relay, kill),
    wait_until(fun() ->
        erpc:call(Node, seq_trace, get_system_tracer, []) =:= false
            andalso erpc:call(Node, erlang, is_process_alive, [Agent]) =:= false
    end, 100).

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

conflicting_agent_beam() ->
    Forms = [
        {attribute, 1, module, beamtrace_agent},
        {attribute, 2, export, [{version, 0}]},
        {function, 3, version, 0, [
            {clause, 3, [], [], [{atom, 3, conflict}]}
        ]}
    ],
    {ok, beamtrace_agent, Beam} = compile:forms(Forms, [binary]),
    Beam.

wait_until(Check, Attempts) when Attempts > 0 ->
    case Check() of
        true -> ok;
        false ->
            timer:sleep(25),
            wait_until(Check, Attempts - 1)
    end;
wait_until(_Check, 0) ->
    error(cleanup_timeout).

with_agent_beam_env(Filename, Test) ->
    Previous = os:getenv("BEAMTRACE_AGENT_BEAM"),
    true = os:putenv("BEAMTRACE_AGENT_BEAM", Filename),
    try Test()
    after
        restore_agent_beam_env(Previous)
    end.

restore_agent_beam_env(false) ->
    true = os:unsetenv("BEAMTRACE_AGENT_BEAM"),
    ok;
restore_agent_beam_env(Value) ->
    true = os:putenv("BEAMTRACE_AGENT_BEAM", Value),
    ok.
