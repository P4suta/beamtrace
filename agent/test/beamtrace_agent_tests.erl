%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_agent_tests).
-include_lib("eunit/include/eunit.hrl").

protocol_version_test() ->
    #{protocol := 2, module_hash := Hash, otp_minimum := 27} =
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

exact_budget_records_a_budget_outcome_instead_of_sampling_test() ->
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
    {budget_reached, event_budget} =
        beamtrace_agent:ingest(Agent, #{kind => 'receive'}),
    #{integrity := {budget_reached, event_budget}, event_count := 2} =
        beamtrace_agent:status(Agent),
    {budget_reached, event_budget} =
        beamtrace_agent:ingest(Agent, #{kind => send}),
    ok = beamtrace_agent:stop(Agent).

byte_and_queue_budgets_stop_exact_capture_without_sampling_test() ->
    lists:foreach(fun({CaptureId, Options, Accepted, Rejected, Reason}) ->
        {ok, Agent} = beamtrace_agent:start_link(self(), maps:merge(
            #{capture_id => CaptureId, mode => exact, batch_size => 10},
            Options
        )),
        lists:foreach(fun(Event) ->
            queued = beamtrace_agent:ingest(Agent, Event)
        end, Accepted),
        {budget_reached, Reason} = beamtrace_agent:ingest(Agent, Rejected),
        receive
            {beamtrace_stop, CaptureId, Node, {budget_reached, Reason}} ->
                ?assertEqual(atom_to_binary(node(), utf8), Node)
        after 1000 ->
            error({missing_budget_stop, Reason})
        end,
        #{integrity := {budget_reached, Reason}, armed := false} =
            beamtrace_agent:status(Agent),
        ok = beamtrace_agent:stop(Agent)
    end, [
        {<<"byte-budget">>, #{max_bytes => 1}, [], #{kind => root}, byte_budget},
        {<<"queue-budget">>, #{max_agent_mailbox => 1},
            [#{kind => root}], #{kind => send}, queue_budget}
    ]).

safety_ttl_reports_the_node_and_restores_global_tracer_state_test() ->
    CaptureId = <<"safety-ttl">>,
    {ok, Agent} = beamtrace_agent:start_link(self(), #{
        capture_id => CaptureId,
        max_duration_ms => 1000,
        drain_timeout_ms => 1000
    }),
    {ok, armed} =
        beamtrace_agent:arm(Agent, {beamtrace_agent_fixture, trigger, 1}),
    Agent ! capture_timeout,
    receive
        {beamtrace_stop, CaptureId, Node, safety_ttl} ->
            ?assertEqual(atom_to_binary(node(), utf8), Node)
    after 1000 ->
        error(missing_safety_ttl_stop)
    end,
    #{integrity := {agent_failure, safety_ttl}, armed := false,
        owns_system_tracer := false} = beamtrace_agent:status(Agent),
    ?assertEqual(false, seq_trace:get_system_tracer()),
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
        {beamtrace_batch, <<"credits">>, Node, 1, Batch} ->
            ?assertEqual(atom_to_binary(node(), utf8), Node),
            ?assertEqual([#{id => 1}, #{id => 2}], Batch)
    after 1000 ->
        ?assert(false)
    end,
    #{queued := 1, credits := 0} = beamtrace_agent:status(Agent),
    ok = beamtrace_agent:stop(Agent).

seal_drains_credit_starved_queue_and_emits_a_verifiable_receipt_test() ->
    {ok, Agent} = beamtrace_agent:start_link(self(), #{
        capture_id => <<"seal-drain">>,
        max_events => 100,
        max_agent_mailbox => 10,
        batch_size => 2
    }),
    queued = beamtrace_agent:ingest(Agent, #{id => 1}),
    queued = beamtrace_agent:ingest(Agent, #{id => 2}),
    queued = beamtrace_agent:ingest(Agent, #{id => 3}),
    {ok, Receipt, verified} = beamtrace_agent:seal(Agent, quiet_period, 1000),
    Batches = collect_sealed_batches([], undefined),
    ?assertEqual([1, 2], [Sequence || {Sequence, _Batch} <- Batches]),
    ?assertEqual(
        [#{id => 1}, #{id => 2}, #{id => 3}],
        lists:append([Batch || {_Sequence, Batch} <- Batches])
    ),
    ?assertEqual(2, maps:get(final_batch_sequence, Receipt)),
    ?assertEqual(3, maps:get(event_count, Receipt)),
    ?assert(maps:get(byte_count, Receipt) > 0),
    ?assertEqual({error, sealing}, beamtrace_agent:ingest(Agent, #{id => 4})),
    ok = beamtrace_agent:stop(Agent).

collect_sealed_batches(Acc, Receipt) ->
    receive
        {beamtrace_batch, <<"seal-drain">>, _Node, Sequence, Batch} ->
            collect_sealed_batches([{Sequence, Batch} | Acc], Receipt);
        {beamtrace_receipt, <<"seal-drain">>, _Node, SeenReceipt, verified} ->
            collect_sealed_batches(Acc, SeenReceipt)
    after 50 ->
        ?assertMatch(#{final_batch_sequence := 2}, Receipt),
        lists:reverse(Acc)
    end.

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
    Orders = [maps:get(local_order, Event) || Event <- Events],
    ?assert(lists:all(
        fun(Order) ->
            is_integer(Order) andalso Order >= 0 andalso Order =< 9007199254740991
        end,
        Orders
    )),
    ?assertEqual(length(Orders), length(lists:usort(Orders))),
    ok = beamtrace_agent:stop(Agent),
    timer:sleep(20),
    ?assertEqual(false, seq_trace:get_system_tracer()),
    Target ! stop.

collect_events(0, Acc) ->
    lists:append(lists:reverse(Acc));
collect_events(Count, Acc) ->
    receive
        {beamtrace_batch, _CaptureId, _Node, _BatchSequence, Batch} ->
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
