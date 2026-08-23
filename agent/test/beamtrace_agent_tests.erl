%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_agent_tests).
-include_lib("eunit/include/eunit.hrl").

protocol_version_test() ->
    #{protocol := 1, module_hash := Hash, otp_minimum := 27} =
        beamtrace_agent:version(),
    ?assert(is_binary(Hash)),
    ?assert(byte_size(Hash) >= 8).

framework_presets_add_semantics_without_changing_generic_classification_test() ->
    From = {self(), make_ref()},
    ?assertEqual(call, beamtrace_agent:semantic({'$gen_call', From, ping}, generic)),
    ?assertEqual(
        gen_server_call,
        beamtrace_agent:semantic({'$gen_call', From, ping}, gen_server)
    ),
    ?assertEqual(
        gleam_actor_call,
        beamtrace_agent:semantic({call, From, ping}, gleam_actor)
    ),
    ?assertEqual(http_request, beamtrace_agent:semantic({request, get, <<"/">>}, wisp_mist)),
    ?assertEqual(
        phoenix_socket_message,
        beamtrace_agent:semantic(
            #{'__struct__' => 'Elixir.Phoenix.Socket.Message'},
            phoenix
        )
    ),
    ?assertEqual(
        supervisor_exit,
        beamtrace_agent:semantic({'EXIT', self(), crashed}, erlang_supervisor)
    ).

unlinked_agent_survives_short_lived_rpc_starter_test() ->
    Parent = self(),
    Starter = spawn(fun() ->
        {ok, Agent} = beamtrace_agent:start(Parent, #{capture_id => <<"unlinked">>}),
        Parent ! {started_agent, Agent}
    end),
    StarterMonitor = erlang:monitor(process, Starter),
    Agent = receive
        {started_agent, Pid} -> Pid
    after 1000 ->
        error(agent_not_started)
    end,
    receive
        {'DOWN', StarterMonitor, process, Starter, normal} -> ok
    after 1000 ->
        error(starter_did_not_exit)
    end,
    ?assert(is_process_alive(Agent)),
    ok = beamtrace_agent:stop(Agent).

metadata_never_contains_scalar_or_binary_value_test() ->
    Secret = <<"SENTINEL-secret-never-leak">>,
    Shaped = beamtrace_agent:shape_term(
        {login, Secret, #{password => <<"hunter2">>}},
        #{mode => metadata, salt => <<"capture-salt">>, max_depth => 8}
    ),
    Encoded = term_to_binary(Shaped),
    ?assertEqual(nomatch, binary:match(Encoded, Secret)),
    ?assertEqual(nomatch, binary:match(Encoded, <<"hunter2">>)),
    ?assertMatch(#{kind := tuple, items := [#{tag := login} | _]}, Shaped).

occupied_system_tracer_is_never_overwritten_test() ->
    Dummy = spawn(fun dummy_tracer/0),
    Previous = seq_trace:set_system_tracer(Dummy),
    try
        ?assertEqual(false, Previous),
        {ok, Agent} = beamtrace_agent:start_link(self(), #{}),
        ?assertEqual(
            {error, {system_tracer_occupied, Dummy}},
            beamtrace_agent:arm(Agent, {beamtrace_agent_fixture, trigger, 1})
        ),
        ?assertEqual(Dummy, seq_trace:get_system_tracer()),
        ok = beamtrace_agent:stop(Agent)
    after
        ?assertEqual(Dummy, seq_trace:set_system_tracer(false)),
        Dummy ! stop
    end.

exact_budget_truncates_instead_of_sampling_test() ->
    {ok, Agent} = beamtrace_agent:start_link(self(), #{
        capture_id => <<"budget">>,
        mode => exact,
        max_events => 2,
        max_bytes => 100000,
        max_agent_mailbox => 10,
        batch_size => 10
    }),
    queued = beamtrace_agent:ingest(Agent, #{kind => root}),
    queued = beamtrace_agent:ingest(Agent, #{kind => send}),
    {truncated, event_budget} =
        beamtrace_agent:ingest(Agent, #{kind => 'receive'}),
    #{completeness := {truncated, event_budget}, event_count := 2} =
        beamtrace_agent:status(Agent),
    {truncated, event_budget} =
        beamtrace_agent:ingest(Agent, #{kind => send}),
    ok = beamtrace_agent:stop(Agent).

credit_batches_are_bounded_test() ->
    {ok, Agent} = beamtrace_agent:start_link(self(), #{
        capture_id => <<"credits">>,
        max_events => 100,
        max_agent_mailbox => 10,
        batch_size => 2
    }),
    queued = beamtrace_agent:ingest(Agent, #{id => 1}),
    queued = beamtrace_agent:ingest(Agent, #{id => 2}),
    queued = beamtrace_agent:ingest(Agent, #{id => 3}),
    ok = beamtrace_agent:grant(Agent, 1),
    receive
        {beamtrace_batch, <<"credits">>, 1, Batch} ->
            ?assertEqual([#{id => 1}, #{id => 2}], Batch)
    after 1000 ->
        ?assert(false)
    end,
    #{queued := 1, credits := 0} = beamtrace_agent:status(Agent),
    ok = beamtrace_agent:stop(Agent).

exact_meta_trigger_and_cleanup_test_() ->
    {timeout, 10, fun exact_meta_trigger_and_cleanup/0}.

argument_shape_filter_is_enforced_by_the_meta_match_spec_test_() ->
    {timeout, 10, fun argument_shape_filter_is_enforced_by_the_meta_match_spec/0}.

argument_shape_filter_is_enforced_by_the_meta_match_spec() ->
    {ok, Agent} = beamtrace_agent:start_link(self(), #{
        capture_id => <<"filtered-root">>,
        mode => exact,
        max_roots => 2,
        root_filter => {arg_tag, 0, equal, <<"allowed">>},
        batch_size => 20
    }),
    ok = beamtrace_agent:grant(Agent, 10),
    {ok, armed} =
        beamtrace_agent:arm(Agent, {beamtrace_agent_fixture, filtered_trigger, 1}),
    {denied, 1} = beamtrace_agent_fixture:filtered_trigger({denied, 1}),
    {allowed, 2} = beamtrace_agent_fixture:filtered_trigger({allowed, 2}),
    Events = collect_events(10, []),
    Roots = [Event || #{kind := root} = Event <- Events],
    ?assertEqual(1, length(Roots)),
    ok = beamtrace_agent:stop(Agent),
    ?assertEqual(false, seq_trace:get_system_tracer()).

exact_meta_trigger_and_cleanup() ->
    Parent = self(),
    Target = spawn(fun() -> echo_loop(Parent) end),
    {ok, Agent} = beamtrace_agent:start_link(self(), #{
        capture_id => <<"exact-e2e">>,
        mode => exact,
        max_events => 100,
        max_agent_mailbox => 100,
        batch_size => 20,
        privacy => #{mode => metadata, salt => <<"e2e-salt">>}
    }),
    ok = beamtrace_agent:grant(Agent, 10),
    {ok, armed} =
        beamtrace_agent:arm(Agent, {beamtrace_agent_fixture, trigger, 1}),
    ok = beamtrace_agent_fixture:trigger(Target),
    Events = collect_events(20, []),
    Kinds = [maps:get(kind, Event) || Event <- Events],
    ?assert(lists:member(root, Kinds)),
    ?assert(lists:member(send, Kinds)),
    ?assert(lists:member('receive', Kinds)),
    ok = beamtrace_agent:stop(Agent),
    timer:sleep(20),
    ?assertEqual(false, seq_trace:get_system_tracer()),
    Target ! stop.

collect_events(0, Acc) ->
    lists:append(lists:reverse(Acc));
collect_events(Count, Acc) ->
    receive
        {beamtrace_batch, _CaptureId, _BatchSequence, Batch} ->
            collect_events(Count - 1, [Batch | Acc]);
        {target_received, _Message} ->
            collect_events(Count, Acc)
    after 50 ->
        lists:append(lists:reverse(Acc))
    end.

echo_loop(Parent) ->
    receive
        {work, From} = Message ->
            Parent ! {target_received, Message},
            From ! ack,
            echo_loop(Parent);
        stop -> ok
    end.

dummy_tracer() ->
    receive
        stop -> ok;
        _ -> dummy_tracer()
    end.
