%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_capture_ffi).

-export([
    collect_remote/9,
    collect_remote_spec/13,
    collect_remote_spec/14,
    collect_distributed/9,
    collect_distributed_spec/13,
    collect_distributed_spec/14,
    probe_remote/2,
    sample_remote/4,
    search_remote/4,
    wait_remote_armed/3,
    wait_remote_available/3
]).

-ifdef(TEST).
-export([new_collect_state/3, track_batch/5, validate_receipt/4]).
-endif.

-define(IDLE_AFTER_ROOT_MS, 250).
-define(DISTRIBUTED_IDLE_AFTER_ROOT_MS, 1000).

wait_remote_armed(NodeBinary, CookieBinary, TimeoutMs)
        when is_integer(TimeoutMs), TimeoutMs > 0, TimeoutMs =< 30000 ->
    case validate_node_cookie(NodeBinary, CookieBinary) of
        ok ->
            Node = binary_to_atom(NodeBinary, utf8),
            Cookie = binary_to_atom(CookieBinary, utf8),
            case connect_hidden(Node, Cookie) of
                {ok, OwnsConnection} ->
                    try
                        wait_remote_armed_loop(
                            Node,
                            erlang:monotonic_time(millisecond) + TimeoutMs
                        )
                    after
                        _ = maybe_disconnect(Node, OwnsConnection)
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end;
wait_remote_armed(_NodeBinary, _CookieBinary, _TimeoutMs) ->
    {error, <<"invalid_arm_wait">>}.

wait_remote_available(NodeBinary, CookieBinary, TimeoutMs)
        when is_integer(TimeoutMs), TimeoutMs > 0, TimeoutMs =< 30000 ->
    case validate_node_cookie(NodeBinary, CookieBinary) of
        ok ->
            Node = binary_to_atom(NodeBinary, utf8),
            Cookie = binary_to_atom(CookieBinary, utf8),
            wait_remote_available_loop(
                Node,
                Cookie,
                erlang:monotonic_time(millisecond) + TimeoutMs
            );
        {error, Reason} -> {error, reason_binary(Reason)}
    end;
wait_remote_available(_NodeBinary, _CookieBinary, _TimeoutMs) ->
    {error, <<"invalid_node_wait">>}.

wait_remote_available_loop(Node, Cookie, Deadline) ->
    case connect_hidden(Node, Cookie) of
        {ok, OwnsConnection} ->
            Result = case beamtrace_relay:probe(Node) of
                #{otp_release := _Release} -> {ok, nil};
                {error, Reason} -> {error, reason_binary(Reason)}
            end,
            _ = maybe_disconnect(Node, OwnsConnection),
            Result;
        {error, _Reason} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, <<"node_start_timeout">>};
                false ->
                    timer:sleep(20),
                    wait_remote_available_loop(Node, Cookie, Deadline)
            end
    end.

wait_remote_armed_loop(Node, Deadline) ->
    case beamtrace_relay:capture_agent_status(Node) of
        {ok, armed} -> {ok, nil};
        {error, not_armed} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, <<"arm_timeout">>};
                false ->
                    timer:sleep(10),
                    wait_remote_armed_loop(Node, Deadline)
            end;
        {error, system_tracer_occupied} ->
            {error, <<"system_tracer_occupied">>};
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

probe_remote(NodeBinary, CookieBinary) ->
    case validate_node_cookie(NodeBinary, CookieBinary) of
        ok ->
            Node = binary_to_atom(NodeBinary, utf8),
            Cookie = binary_to_atom(CookieBinary, utf8),
            case connect_hidden(Node, Cookie) of
                {ok, OwnsConnection} ->
                    try
                        case beamtrace_relay:probe(Node) of
                            #{otp_release := Release} -> {ok, Release};
                            {error, Reason} -> {error, reason_binary(Reason)}
                        end
                    after
                        _ = maybe_disconnect(Node, OwnsConnection)
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

sample_remote(NodeBinary, CookieBinary, Offset, Limit)
        when is_integer(Offset), Offset >= 0,
             is_integer(Limit), Limit > 0, Limit =< 1000 ->
    case validate_node_cookie(NodeBinary, CookieBinary) of
        ok ->
            Node = binary_to_atom(NodeBinary, utf8),
            Cookie = binary_to_atom(CookieBinary, utf8),
            case connect_hidden(Node, Cookie) of
                {ok, OwnsConnection} ->
                    try
                        case beamtrace_relay:sample_processes(Node, Offset, Limit) of
                            {ok, Samples, NextOffset} ->
                                {ok, {[sample_to_raw(Sample) || Sample <- Samples], NextOffset}};
                            {error, Reason} -> {error, reason_binary(Reason)}
                        end
                    after
                        _ = maybe_disconnect(Node, OwnsConnection)
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end;
sample_remote(_NodeBinary, _CookieBinary, _Offset, _Limit) ->
    {error, <<"invalid_sample_window">>}.

search_remote(NodeBinary, CookieBinary, Query, Limit)
        when is_binary(Query), byte_size(Query) =< 256,
             is_integer(Limit), Limit > 0, Limit =< 200 ->
    case validate_node_cookie(NodeBinary, CookieBinary) of
        ok ->
            Node = binary_to_atom(NodeBinary, utf8),
            Cookie = binary_to_atom(CookieBinary, utf8),
            case connect_hidden(Node, Cookie) of
                {ok, OwnsConnection} ->
                    try
                        case beamtrace_relay:search_mfas(Node, Query, Limit) of
                            {ok, Candidates} ->
                                {ok, [mfa_candidate_to_raw(Node, Candidate) || Candidate <- Candidates]};
                            {error, Reason} -> {error, reason_binary(Reason)}
                        end
                    after
                        _ = maybe_disconnect(Node, OwnsConnection)
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end;
search_remote(_NodeBinary, _CookieBinary, _Query, _Limit) ->
    {error, <<"invalid_mfa_search">>}.

mfa_candidate_to_raw(Node, Candidate) ->
    {mfa_candidate,
        atom_to_binary(Node, utf8),
        as_binary(maps:get(module, Candidate, <<>>)),
        as_binary(maps:get(function, Candidate, <<>>)),
        integer_value(maps:get(arity, Candidate, 0))}.

collect_distributed(
    NodeBinaries,
    CookieBinary,
    ModuleBinary,
    FunctionBinary,
    Arity,
    CaptureWindowMs,
    MaxEvents,
    MaxBytes,
    MaxAgentMailbox
) ->
    collect_distributed_spec(
        NodeBinaries,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs,
        MaxEvents,
        MaxBytes,
        MaxAgentMailbox,
        1,
        agent_always,
        metadata,
        generic
    ).

collect_distributed_spec(
    NodeBinaries,
    CookieBinary,
    ModuleBinary,
    FunctionBinary,
    Arity,
    CaptureWindowMs,
    MaxEvents,
    MaxBytes,
    MaxAgentMailbox,
    MaxRoots,
    Predicate,
    Privacy,
    Preset
) ->
    collect_distributed_spec(
        NodeBinaries,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs,
        10000,
        MaxEvents,
        MaxBytes,
        MaxAgentMailbox,
        MaxRoots,
        Predicate,
        Privacy,
        Preset
    ).

collect_distributed_spec(
    NodeBinaries,
    CookieBinary,
    ModuleBinary,
    FunctionBinary,
    Arity,
    CaptureWindowMs,
    DrainTimeoutMs,
    MaxEvents,
    MaxBytes,
    MaxAgentMailbox,
    MaxRoots,
    Predicate,
    Privacy,
    Preset
) ->
    case {validate_distributed_inputs(
        NodeBinaries,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs
    ), capture_options(MaxRoots, DrainTimeoutMs, Predicate, Privacy, Preset)} of
        {ok, {ok, ExtraOptions}} ->
            Nodes = [binary_to_atom(NodeBinary, utf8) || NodeBinary <- NodeBinaries],
            Cookie = binary_to_atom(CookieBinary, utf8),
            Module = binary_to_atom(ModuleBinary, utf8),
            Function = binary_to_atom(FunctionBinary, utf8),
            case connect_nodes(Nodes, Cookie, []) of
                {ok, Connections} ->
                    try
                        run_distributed(
                            Connections,
                            {Module, Function, Arity},
                            CaptureWindowMs,
                            MaxEvents,
                            MaxBytes,
                            MaxAgentMailbox,
                            ExtraOptions
                        )
                    after
                        disconnect_owned(Connections)
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {{error, Reason}, _} -> {error, reason_binary(Reason)};
        {_, {error, Reason}} -> {error, reason_binary(Reason)}
    end.

run_distributed(
    Connections,
    MFA,
    WindowMs,
    MaxEvents,
    MaxBytes,
    MaxAgentMailbox,
    ExtraOptions
) ->
    CaptureId = capture_id(),
    %% Keep labels inside the historical immediate-integer range. This is
    %% understood by every supported distribution peer and avoids silently
    %% dropping a token when mixed runtimes negotiate conservative encoding.
    Label = 1 + (binary:decode_unsigned(
        'beamtrace_runtime@crypto':random_bytes(4)
    ) rem 134217726),
    Options = maps:merge(#{
        capture_id => CaptureId,
        trace_label => Label,
        mode => exact,
        max_events => positive(MaxEvents, 100000),
        max_bytes => positive(MaxBytes, 64000000),
        max_agent_mailbox => positive(MaxAgentMailbox, 10000),
        max_duration_ms => positive(WindowMs, 30000),
        batch_size => 128
    }, ExtraOptions),
    case prepare_nodes(Connections, Options, []) of
        {ok, Prepared} ->
            try setup_distributed(
                Prepared,
                MFA,
                Label,
                CaptureId,
                WindowMs,
                maps:get(drain_timeout_ms, Options, 10000)
            )
            after
                cleanup_prepared(Prepared)
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

prepare_nodes([], _Options, Accumulator) ->
    {ok, lists:reverse(Accumulator)};
prepare_nodes([{Node, _OwnsConnection} | Rest], Options, Accumulator) ->
    case beamtrace_relay:inject(Node) of
        {ok, Disposition, Digest} ->
            case beamtrace_relay:start_agent(Node, self(), Options) of
                {ok, Agent} ->
                    prepare_nodes(
                        Rest,
                        Options,
                        [{Node, Digest, Agent, Disposition} | Accumulator]
                    );
                {error, Reason} ->
                    _ = maybe_unload_unstarted(Node, Digest, Disposition),
                    cleanup_prepared(Accumulator),
                    {error, Reason}
            end;
        {error, Reason} ->
            cleanup_prepared(Accumulator),
            {error, Reason}
    end.

setup_distributed(Prepared, MFA, Label, CaptureId, WindowMs, DrainTimeoutMs) ->
    case grant_all(Prepared) of
        ok ->
            Root = hd(Prepared),
            Passives = tl(Prepared),
            case listen_all(Passives, Label) of
                ok ->
                    {RootNode, _RootDigest, RootAgent, _RootDisposition} = Root,
                    Nodes = [Node || {Node, _Digest, _Agent, _Disposition} <- Prepared],
                    BeforeClocks = clock_probe_phase(Nodes),
                    case beamtrace_relay:arm_agent(RootNode, RootAgent, MFA) of
                        {ok, armed} ->
                            monitor_nodes(Nodes, true),
                            try
                                Deadline = erlang:monotonic_time(millisecond) + WindowMs,
                                Collected = collect_batches_multi(
                                    Nodes,
                                    Prepared,
                                    CaptureId,
                                    Deadline,
                                    undefined,
                                    false,
                                    [],
                                    [],
                                    new_collect_state(
                                        DrainTimeoutMs,
                                        WindowMs,
                                        ?DISTRIBUTED_IDLE_AFTER_ROOT_MS
                                    )
                                ),
                                attach_clock_phases(
                                    Collected,
                                    BeforeClocks,
                                    clock_probe_phase(Nodes)
                                )
                            after
                                monitor_nodes(Nodes, false)
                            end;
                        {error, {system_tracer_occupied, _}} ->
                            {error, <<"system_tracer_occupied">>};
                        {error, Reason} -> {error, reason_binary(Reason)}
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

grant_all([]) -> ok;
grant_all([{Node, _Digest, Agent, _Disposition} | Rest]) ->
    case beamtrace_relay:grant(Node, Agent, initial_batch_credits()) of
        ok -> grant_all(Rest);
        {error, Reason} -> {error, Reason}
    end.

listen_all([], _Label) -> ok;
listen_all([{Node, _Digest, Agent, _Disposition} | Rest], Label) ->
    case beamtrace_relay:listen_agent(Node, Agent, Label) of
        {ok, listening} -> listen_all(Rest, Label);
        {error, Reason} -> {error, Reason}
    end.

collect_batches_multi(
    Nodes,
    Prepared,
    CaptureId,
    Deadline,
    IdleDeadline,
    SeenRoot,
    Acc,
    Missing,
    CreditDebt
) ->
    Now = erlang:monotonic_time(millisecond),
    Wait = wait_time(Now, Deadline, IdleDeadline, SeenRoot),
    case Wait =< 0 of
        true ->
            case SeenRoot of
                false -> {error, <<"trigger_timeout">>};
                true ->
                    {EndKind, EndDetail} = end_reason(
                        Now, Deadline, IdleDeadline, CreditDebt
                    ),
                    seal_multi(
                        Prepared, CaptureId, EndKind, EndDetail,
                        Acc, Missing, CreditDebt
                    )
            end;
        false ->
            receive
                beamtrace_cancel ->
                    seal_multi(
                        Prepared, CaptureId, <<"user_stopped">>, <<>>,
                        Acc, Missing, CreditDebt
                    );
                {beamtrace_batch, CaptureId, BatchNode, Sequence, Batch} ->
                    {Accepted, TrackedDebt} = track_multi_batch(
                        BatchNode, Sequence, Batch, CreditDebt
                    ),
                    Raw = case Accepted of true -> raw_events(Batch); false -> [] end,
                    HasRoot = lists:any(fun is_root/1, Raw),
                    Seen = SeenRoot orelse HasRoot,
                    case replenish_multi_credit(Batch, Prepared, TrackedDebt) of
                        {ok, NextDebt} ->
                            NewIdle = case Seen of
                                true -> erlang:monotonic_time(millisecond)
                                    + ?DISTRIBUTED_IDLE_AFTER_ROOT_MS;
                                false -> undefined
                            end,
                            collect_batches_multi(
                                Nodes,
                                Prepared,
                                CaptureId,
                                Deadline,
                                NewIdle,
                                Seen,
                                [Raw | Acc],
                                Missing,
                                NextDebt
                            );
                        {error, _Reason} ->
                            seal_multi(
                                Prepared, CaptureId,
                                <<"agent_failure">>, <<"credit_replenish_failed">>,
                                [Raw | Acc], Missing,
                                add_multi_issue(TrackedDebt, raw_issue(
                                    <<"legacy_unverified">>, BatchNode,
                                    <<"credit_replenish_failed">>, 0, 0
                                ))
                            )
                    end;
                {beamtrace_stop, CaptureId, _BatchNode, {budget_reached, Reason}} ->
                    seal_multi(
                        Prepared, CaptureId,
                        <<"budget_reached">>, atom_binary(Reason),
                        Acc, Missing, CreditDebt
                    );
                {beamtrace_stop, CaptureId, {budget_reached, Reason}} ->
                    %% Protocol-v1 migration input did not identify the node.
                    seal_multi(
                        Prepared, CaptureId,
                        <<"budget_reached">>, atom_binary(Reason),
                        Acc, Missing, CreditDebt
                    );
                {beamtrace_stop, CaptureId, BatchNode, safety_ttl} ->
                    FailedNode = binary_to_atom(BatchNode, utf8),
                    seal_multi(
                        Prepared, CaptureId,
                        <<"agent_failure">>, <<"safety_ttl">>,
                        Acc, lists:usort([FailedNode | Missing]),
                        CreditDebt
                    );
                {beamtrace_stop, CaptureId, safety_ttl} ->
                    %% Protocol-v1 migration input cannot identify which agent
                    %% expired, so the outcome must remain explicitly
                    %% unverified.
                    seal_multi(
                        Prepared, CaptureId,
                        <<"agent_failure">>, <<"safety_ttl">>,
                        Acc, Missing,
                        add_multi_issue(CreditDebt, raw_issue(
                            <<"legacy_unverified">>, <<>>,
                            <<"safety_ttl_without_node">>, 0, 0
                        ))
                    );
                {beamtrace_stop, CaptureId, {truncated, Reason}} ->
                    %% Protocol-v1 migration input. New agents emit
                    %% {budget_reached, Reason}.
                    seal_multi(
                        Prepared, CaptureId,
                        <<"budget_reached">>, atom_binary(Reason),
                        Acc, Missing, CreditDebt
                    );
                {nodedown, Node} ->
                    NextMissing = case lists:member(Node, Nodes) of
                        true -> lists:usort([Node | Missing]);
                        false -> Missing
                    end,
                    collect_batches_multi(
                        Nodes,
                        Prepared,
                        CaptureId,
                        Deadline,
                        IdleDeadline,
                        SeenRoot,
                        Acc,
                        NextMissing,
                        CreditDebt
                    );
                _Other ->
                    collect_batches_multi(
                        Nodes,
                        Prepared,
                        CaptureId,
                        Deadline,
                        IdleDeadline,
                        SeenRoot,
                        Acc,
                        Missing,
                        CreditDebt
                    )
            after Wait ->
                case SeenRoot of
                    false -> {error, <<"trigger_timeout">>};
                    true ->
                        Current = erlang:monotonic_time(millisecond),
                        {EndKind, EndDetail} = end_reason(
                            Current, Deadline, IdleDeadline, CreditDebt
                        ),
                        seal_multi(
                            Prepared, CaptureId, EndKind, EndDetail,
                            Acc, Missing, CreditDebt
                        )
                end
            end
    end.

cleanup_prepared(Prepared) ->
    lists:foreach(fun({Node, Digest, Agent, Disposition}) ->
        _ = beamtrace_relay:stop_agent(Node, Agent),
        _ = maybe_unload(Node, Digest, Agent, Disposition),
        ok
    end, Prepared),
    ok.

track_multi_batch(NodeBinary, Sequence, Batch, State) ->
    Key = {tracking, NodeBinary},
    NodeState = maps:get(Key, State, new_collect_state(
        drain_timeout(State),
        capture_window(State),
        quiet_period(State)
    )),
    {Accepted, Tracked} = track_batch(NodeBinary, NodeBinary, Sequence, Batch, NodeState),
    Issues = maps:get(issues, State, []) ++ maps:get(issues, Tracked, []),
    {Accepted, State#{Key => Tracked#{issues => []}, issues => Issues}}.

seal_multi(Prepared, CaptureId, EndKind, EndDetail, Acc, Missing, State) ->
    Parent = self(),
    Reference = make_ref(),
    DrainTimeoutMs = drain_timeout(State),
    Pending = [Node || {Node, _Digest, _Agent, _Disposition} <- Prepared,
        not lists:member(Node, Missing)],
    _ = [spawn(fun() ->
        Parent ! {beamtrace_seal_result, Reference, Node,
            beamtrace_relay:seal_agent(Node, Agent, EndKind, DrainTimeoutMs)}
    end) || {Node, _Digest, Agent, _Disposition} <- Prepared,
            lists:member(Node, Pending)],
    WithMissing = lists:foldl(fun(Node, Current) ->
        add_multi_issue(Current, raw_issue(
            <<"missing_node">>, atom_to_binary(Node, utf8), <<>>, 0, 0
        ))
    end, State, Missing),
    drain_multi(
        CaptureId, Reference, Pending, EndKind, EndDetail,
        Acc, WithMissing, [],
        erlang:monotonic_time(millisecond) + DrainTimeoutMs + 2000
    ).

drain_multi(
    _CaptureId, _Reference, [], EndKind, EndDetail,
    Acc, State, Receipts, _Deadline
) ->
    finish_multi(flatten(Acc), EndKind, EndDetail, State, Receipts);
drain_multi(
    CaptureId, Reference, Pending, EndKind, EndDetail,
    Acc, State, Receipts, Deadline
) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {beamtrace_batch, CaptureId, BatchNode, Sequence, Batch} ->
            {Accepted, Tracked} = track_multi_batch(BatchNode, Sequence, Batch, State),
            Raw = case Accepted of true -> raw_events(Batch); false -> [] end,
            drain_multi(
                CaptureId, Reference, Pending, EndKind, EndDetail,
                [Raw | Acc], Tracked, Receipts, Deadline
            );
        {beamtrace_receipt, CaptureId, NodeBinary, Receipt, Status} ->
            Node = binary_to_atom(NodeBinary, utf8),
            NodeState = maps:get(
                {tracking, NodeBinary},
                State,
                new_collect_state(
                    drain_timeout(State),
                    capture_window(State),
                    quiet_period(State)
                )
            ),
            CheckedNode = validate_receipt(NodeBinary, Receipt, Status, NodeState),
            NextState = merge_multi_issues(State, CheckedNode),
            drain_multi(
                CaptureId, Reference, lists:delete(Node, Pending),
                EndKind, EndDetail, Acc, NextState,
                [{NodeBinary, Receipt} | Receipts], Deadline
            );
        {beamtrace_seal_result, Reference, Node, {error, Reason}} ->
            NodeBinary = atom_to_binary(Node, utf8),
            Next = add_multi_issue(State, raw_issue(
                <<"drain_timeout">>, NodeBinary, reason_binary(Reason), 0,
                drain_timeout(State)
            )),
            drain_multi(
                CaptureId, Reference, lists:delete(Node, Pending),
                EndKind, EndDetail, Acc, Next, Receipts, Deadline
            );
        {beamtrace_seal_result, Reference, _Node, {ok, _Receipt, _Status}} ->
            drain_multi(
                CaptureId, Reference, Pending, EndKind, EndDetail,
                Acc, State, Receipts, Deadline
            );
        {nodedown, Node} ->
            NodeBinary = atom_to_binary(Node, utf8),
            Next = add_multi_issue(State, raw_issue(
                <<"missing_node">>, NodeBinary, <<>>, 0, 0
            )),
            drain_multi(
                CaptureId, Reference, lists:delete(Node, Pending),
                EndKind, EndDetail, Acc, Next, Receipts, Deadline
            )
    after Remaining ->
        TimedOut = lists:foldl(fun(Node, Current) ->
            add_multi_issue(Current, raw_issue(
                <<"drain_timeout">>, atom_to_binary(Node, utf8), <<>>, 0,
                drain_timeout(State)
            ))
        end, State, Pending),
        finish_multi(flatten(Acc), EndKind, EndDetail, TimedOut, Receipts)
    end.

add_multi_issue(State, Issue) ->
    State#{issues => [Issue | maps:get(issues, State, [])]}.

merge_multi_issues(State, NodeState) ->
    lists:foldl(fun(Issue, Current) -> add_multi_issue(Current, Issue) end,
        State, maps:get(issues, NodeState, [])).

finish_multi(Events, EndKind, EndDetail, State, Receipts) ->
    RawReceipts = [{raw_node_receipt,
        NodeBinary,
        maps:get(final_batch_sequence, Receipt, 0),
        maps:get(event_count, Receipt, 0),
        maps:get(byte_count, Receipt, 0)}
        || {NodeBinary, Receipt} <- Receipts],
    Clocks = [{node_clock,
        NodeBinary,
        maps:get(origin_local_ns, Receipt, 0),
        none,
        none}
        || {NodeBinary, Receipt} <- Receipts],
    Outcome = {raw_outcome, EndKind, EndDetail,
        lists:reverse(maps:get(issues, State, [])), RawReceipts},
    {ok, {Events, Outcome, {clock_calibration, 0, Clocks}}}.

monitor_nodes(Nodes, Enabled) ->
    lists:foreach(fun(Node) -> monitor_node(Node, Enabled) end, Nodes).

connect_nodes([], _Cookie, Accumulator) -> {ok, lists:reverse(Accumulator)};
connect_nodes([Node | Rest], Cookie, Accumulator) ->
    case connect_hidden(Node, Cookie) of
        {ok, OwnsConnection} ->
            connect_nodes(Rest, Cookie, [{Node, OwnsConnection} | Accumulator]);
        {error, Reason} ->
            disconnect_owned(Accumulator),
            {error, Reason}
    end.

disconnect_owned(Connections) ->
    lists:foreach(fun({Node, OwnsConnection}) ->
        _ = maybe_disconnect(Node, OwnsConnection),
        ok
    end, Connections),
    ok.

validate_distributed_inputs(
    [First | _] = Nodes,
    Cookie,
    Module,
    Function,
    Arity,
    Window
) when length(Nodes) =< 32 ->
    case validate_inputs(First, Cookie, Module, Function, Arity, Window) of
        ok ->
            case lists:all(fun(Node) -> validate_node_cookie(Node, Cookie) =:= ok end, Nodes) of
                true -> ok;
                false -> {error, invalid_node_name}
            end;
        Error -> Error
    end;
validate_distributed_inputs(_Nodes, _Cookie, _Module, _Function, _Arity, _Window) ->
    {error, invalid_capture_arguments}.

sample_to_raw(Sample) ->
    {raw_process_sample,
        as_binary(maps:get(node, Sample, <<>>)),
        as_binary(maps:get(pid, Sample, <<>>)),
        optional_binary(maps:get(registered_name, Sample, undefined)),
        optional_binary(maps:get(process_label, Sample, undefined)),
        optional_mfa_binary(maps:get(initial_call, Sample, undefined)),
        integer_value(maps:get(message_queue_len, Sample, 0)),
        integer_value(maps:get(memory, Sample, 0)),
        integer_value(maps:get(reductions, Sample, 0)),
        integer_value(maps:get(heap_size, Sample, 0)),
        integer_value(maps:get(total_heap_size, Sample, 0)),
        integer_value(maps:get(link_count, Sample, 0)),
        optional_binary(maps:get(status, Sample, undefined)),
        optional_mfa_binary(maps:get(current_function, Sample, undefined)),
        string_list(maps:get(links, Sample, [])),
        string_list(maps:get(ancestors, Sample, []))}.

optional_binary(undefined) -> <<>>;
optional_binary(Value) -> as_binary(Value).

optional_mfa_binary({Module, Function, Arity})
        when is_atom(Module), is_atom(Function), is_integer(Arity), Arity >= 0 ->
    <<(atom_to_binary(Module, utf8))/binary, ":",
      (atom_to_binary(Function, utf8))/binary, "/",
      (integer_to_binary(Arity))/binary>>;
optional_mfa_binary(Value) -> optional_binary(Value).

string_list(Values) when is_list(Values) ->
    [as_binary(Value) || Value <- lists:sublist(Values, 32)];
string_list(_Values) -> [].

collect_remote(
    NodeBinary,
    CookieBinary,
    ModuleBinary,
    FunctionBinary,
    Arity,
    CaptureWindowMs,
    MaxEvents,
    MaxBytes,
    MaxAgentMailbox
) ->
    collect_remote_spec(
        NodeBinary,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs,
        MaxEvents,
        MaxBytes,
        MaxAgentMailbox,
        1,
        agent_always,
        metadata,
        generic
    ).

collect_remote_spec(
    NodeBinary,
    CookieBinary,
    ModuleBinary,
    FunctionBinary,
    Arity,
    CaptureWindowMs,
    MaxEvents,
    MaxBytes,
    MaxAgentMailbox,
    MaxRoots,
    Predicate,
    Privacy,
    Preset
) ->
    collect_remote_spec(
        NodeBinary,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs,
        10000,
        MaxEvents,
        MaxBytes,
        MaxAgentMailbox,
        MaxRoots,
        Predicate,
        Privacy,
        Preset
    ).

collect_remote_spec(
    NodeBinary,
    CookieBinary,
    ModuleBinary,
    FunctionBinary,
    Arity,
    CaptureWindowMs,
    DrainTimeoutMs,
    MaxEvents,
    MaxBytes,
    MaxAgentMailbox,
    MaxRoots,
    Predicate,
    Privacy,
    Preset
) ->
    case {validate_inputs(
        NodeBinary,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs
    ), capture_options(MaxRoots, DrainTimeoutMs, Predicate, Privacy, Preset)} of
        {ok, {ok, ExtraOptions}} ->
            Node = binary_to_atom(NodeBinary, utf8),
            Module = binary_to_atom(ModuleBinary, utf8),
            Function = binary_to_atom(FunctionBinary, utf8),
            Cookie = binary_to_atom(CookieBinary, utf8),
            case connect_hidden(Node, Cookie) of
                {ok, OwnsConnection} ->
                    try run_capture(
                        Node,
                        {Module, Function, Arity},
                        CaptureWindowMs,
                        MaxEvents,
                        MaxBytes,
                        MaxAgentMailbox,
                        ExtraOptions
                    )
                    after
                        _ = maybe_disconnect(Node, OwnsConnection)
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {{error, Reason}, _} ->
            {error, reason_binary(Reason)};
        {_, {error, Reason}} ->
            {error, reason_binary(Reason)}
    end.

run_capture(Node, MFA, WindowMs, MaxEvents, MaxBytes, MaxAgentMailbox, ExtraOptions) ->
    case beamtrace_relay:inject(Node) of
        {ok, Disposition, Digest} ->
            CaptureId = capture_id(),
            Options = maps:merge(#{
                capture_id => CaptureId,
                mode => exact,
                max_events => positive(MaxEvents, 100000),
                max_bytes => positive(MaxBytes, 64000000),
                max_agent_mailbox => positive(MaxAgentMailbox, 10000),
                max_duration_ms => positive(WindowMs, 30000),
                batch_size => 128
            }, ExtraOptions),
            run_injected(
                Node,
                MFA,
                WindowMs,
                Digest,
                Disposition,
                CaptureId,
                Options
            );
        {error, Reason} ->
            {error, reason_binary(Reason)}
    end.

run_injected(Node, MFA, WindowMs, Digest, Disposition, CaptureId, Options) ->
    case beamtrace_relay:start_agent(Node, self(), Options) of
        {ok, Agent} ->
            try
                BeforeClocks = clock_probe_phase([Node]),
                case beamtrace_relay:grant(Node, Agent, initial_batch_credits()) of
                    ok ->
                        case beamtrace_relay:arm_agent(Node, Agent, MFA) of
                            {ok, armed} ->
                                monitor_node(Node, true),
                                Deadline = erlang:monotonic_time(millisecond) + WindowMs,
                                Collected = collect_batches(
                                    Node,
                                    Agent,
                                    CaptureId,
                                    Deadline,
                                    undefined,
                                    false,
                                    [],
                                    new_collect_state(
                                        maps:get(drain_timeout_ms, Options, 10000),
                                        WindowMs,
                                        ?IDLE_AFTER_ROOT_MS
                                    )
                                ),
                                attach_clock_phases(
                                    Collected,
                                    BeforeClocks,
                                    clock_probe_phase([Node])
                                );
                            {error, {system_tracer_occupied, _}} ->
                                {error, <<"system_tracer_occupied">>};
                            {error, Reason} ->
                                {error, reason_binary(Reason)}
                        end;
                    {error, Reason} ->
                        {error, reason_binary(Reason)}
                end
            after
                monitor_node(Node, false),
                _ = beamtrace_relay:stop_agent(Node, Agent),
                _ = maybe_unload(Node, Digest, Agent, Disposition)
            end;
        {error, Reason} ->
            _ = maybe_unload_unstarted(Node, Digest, Disposition),
            {error, reason_binary(Reason)}
    end.

maybe_unload(Node, Digest, Agent, loaded) ->
    beamtrace_relay:unload(Node, Digest, Agent);
maybe_unload(_Node, _Digest, _Agent, reused) ->
    ok.

maybe_unload_unstarted(Node, Digest, loaded) ->
    beamtrace_relay:unload_unstarted(Node, Digest);
maybe_unload_unstarted(_Node, _Digest, reused) ->
    ok.

collect_batches(Node, Agent, CaptureId, Deadline, IdleDeadline, SeenRoot, Acc, CollectState) ->
    Now = erlang:monotonic_time(millisecond),
    Wait = wait_time(Now, Deadline, IdleDeadline, SeenRoot),
    case Wait =< 0 of
        true ->
            case SeenRoot of
                false -> {error, <<"trigger_timeout">>};
                true ->
                    {EndKind, EndDetail} = end_reason(
                        Now, Deadline, IdleDeadline, CollectState
                    ),
                    seal_single(Node, Agent, CaptureId, EndKind, EndDetail, Acc, CollectState)
            end;
        false ->
            receive
                beamtrace_cancel ->
                    seal_single(Node, Agent, CaptureId, <<"user_stopped">>, <<>>, Acc,
                        CollectState);
                {beamtrace_batch, CaptureId, BatchNode, Sequence, Batch} ->
                    {Accepted, TrackedState} = track_batch(
                        atom_to_binary(Node, utf8), BatchNode, Sequence, Batch, CollectState
                    ),
                    Raw = case Accepted of
                        true -> raw_events(Batch);
                        false -> []
                    end,
                    HasRoot = lists:any(fun is_root/1, Raw),
                    Seen = SeenRoot orelse HasRoot,
                    Debt = maps:get(debt, TrackedState, 0) + 1,
                    case replenish_credit(Node, Agent, Debt) of
                        {ok, NextDebt} ->
                            NewIdle = case Seen of
                                true -> erlang:monotonic_time(millisecond)
                                    + ?IDLE_AFTER_ROOT_MS;
                                false -> undefined
                            end,
                            collect_batches(
                                Node,
                                Agent,
                                CaptureId,
                                Deadline,
                                NewIdle,
                                Seen,
                                [Raw | Acc],
                                TrackedState#{debt => NextDebt}
                            );
                        {error, _Reason} ->
                            seal_single(
                                Node, Agent, CaptureId,
                                <<"agent_failure">>, <<"credit_replenish_failed">>,
                                [Raw | Acc],
                                add_issue(TrackedState, raw_issue(
                                    <<"legacy_unverified">>, BatchNode,
                                    <<"credit_replenish_failed">>, 0, 0
                                ))
                            )
                    end;
                {beamtrace_stop, CaptureId, _BatchNode, {budget_reached, Reason}} ->
                    seal_single(
                        Node, Agent, CaptureId,
                        <<"budget_reached">>, atom_binary(Reason), Acc, CollectState
                    );
                {beamtrace_stop, CaptureId, {budget_reached, Reason}} ->
                    %% Protocol-v1 migration input.
                    seal_single(
                        Node, Agent, CaptureId,
                        <<"budget_reached">>, atom_binary(Reason), Acc, CollectState
                    );
                {beamtrace_stop, CaptureId, {truncated, Reason}} ->
                    %% Protocol-v1 migration input.
                    seal_single(
                        Node, Agent, CaptureId,
                        <<"budget_reached">>, atom_binary(Reason), Acc, CollectState
                    );
                {beamtrace_stop, CaptureId, BatchNode, safety_ttl} ->
                    finish_unsealed(
                        flatten(Acc), <<"agent_failure">>, <<"safety_ttl">>,
                        add_issue(CollectState, raw_issue(
                            <<"missing_node">>, BatchNode, <<>>, 0, 0
                        ))
                    );
                {beamtrace_stop, CaptureId, safety_ttl} ->
                    %% Protocol-v1 migration input.
                    finish_unsealed(
                        flatten(Acc), <<"agent_failure">>, <<"safety_ttl">>,
                        add_issue(CollectState, raw_issue(
                            <<"missing_node">>, atom_to_binary(Node, utf8), <<>>, 0, 0
                        ))
                    );
                {nodedown, Node} ->
                    finish_unsealed(
                        flatten(Acc), <<"agent_failure">>, <<"node_down">>,
                        add_issue(CollectState, raw_issue(
                            <<"missing_node">>, atom_to_binary(Node, utf8), <<>>, 0, 0
                        ))
                    );
                _Other ->
                    collect_batches(
                        Node,
                        Agent,
                        CaptureId,
                        Deadline,
                        IdleDeadline,
                        SeenRoot,
                        Acc,
                        CollectState
                    )
            after Wait ->
                case SeenRoot of
                    false -> {error, <<"trigger_timeout">>};
                    true ->
                        Current = erlang:monotonic_time(millisecond),
                        {EndKind, EndDetail} = end_reason(
                            Current, Deadline, IdleDeadline, CollectState
                        ),
                        seal_single(
                            Node, Agent, CaptureId, EndKind, EndDetail, Acc, CollectState
                        )
                end
            end
    end.

replenish_credit(Node, Agent, Debt) ->
    case Debt >= refill_batch_count() of
        true ->
            case beamtrace_relay:grant(Node, Agent, Debt) of
                ok -> {ok, 0};
                {error, Reason} -> {error, Reason}
            end;
        false -> {ok, Debt}
    end.

new_collect_state(DrainTimeoutMs, WindowMs, QuietPeriodMs) ->
    #{debt => 0, last_sequence => 0, event_count => 0, byte_count => 0,
      issues => [], drain_timeout_ms => DrainTimeoutMs,
      capture_window_ms => WindowMs, quiet_period_ms => QuietPeriodMs}.

drain_timeout(State) ->
    maps:get(drain_timeout_ms, State, 10000).

capture_window(State) ->
    maps:get(capture_window_ms, State, 0).

quiet_period(State) ->
    maps:get(quiet_period_ms, State, ?IDLE_AFTER_ROOT_MS).

track_batch(ExpectedNode, BatchNode, Sequence, Batch, State) ->
    Last = maps:get(last_sequence, State, 0),
    Expected = Last + 1,
    case BatchNode =:= ExpectedNode of
        false ->
            {false, add_issue(State, raw_issue(
                <<"legacy_unverified">>, BatchNode, <<"unexpected_batch_node">>, 0, 0
            ))};
        true when Sequence =< Last ->
            {false, add_issue(State, raw_issue(
                <<"duplicate_batch">>, BatchNode, <<>>, 0, Sequence
            ))};
        true ->
            Events = accepted_batch_events(Batch),
            Bytes = lists:sum([erlang:external_size(Event) || Event <- Events]),
            WithGap = case Sequence =:= Expected of
                true -> State;
                false -> add_issue(State, raw_issue(
                    <<"batch_sequence_gap">>, BatchNode, <<>>, Expected, Sequence
                ))
            end,
            {true, WithGap#{
                last_sequence => Sequence,
                event_count => maps:get(event_count, WithGap, 0) + length(Events),
                byte_count => maps:get(byte_count, WithGap, 0) + Bytes
            }}
    end.

accepted_batch_events(Batch) ->
    [Event || Event <- Batch, is_map(Event), maps:is_key(id, Event)].

raw_issue(Kind, Node, Field, Expected, Actual) ->
    {raw_capture_issue, Kind, Node, Field, Expected, Actual}.

add_issue(State, Issue) ->
    State#{issues => [Issue | maps:get(issues, State, [])]}.

end_reason(Now, Deadline, IdleDeadline, State)
        when is_integer(IdleDeadline), IdleDeadline =< Deadline, Now >= IdleDeadline ->
    {<<"quiet_period">>, integer_to_binary(quiet_period(State))};
end_reason(_Now, _Deadline, _IdleDeadline, State) ->
    {<<"time_window">>, integer_to_binary(capture_window(State))}.

seal_single(Node, Agent, CaptureId, EndKind, EndDetail, Acc, State) ->
    DrainTimeoutMs = drain_timeout(State),
    case beamtrace_relay:seal_agent(Node, Agent, EndKind, DrainTimeoutMs) of
        {ok, Receipt, SealStatus} ->
            drain_single(
                Node, CaptureId, EndKind, EndDetail, Acc, State,
                Receipt, SealStatus,
                erlang:monotonic_time(millisecond) + DrainTimeoutMs + 1000
            );
        {error, Reason} ->
            NodeBinary = atom_to_binary(Node, utf8),
            finish_unsealed(
                flatten(Acc), <<"agent_failure">>, reason_binary(Reason),
                add_issue(State, raw_issue(
                    <<"drain_timeout">>, NodeBinary, <<>>, 0, DrainTimeoutMs
                ))
            )
    end.

drain_single(
    Node, CaptureId, EndKind, EndDetail, Acc, State,
    ReplyReceipt, ReplyStatus, Deadline
) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {beamtrace_batch, CaptureId, BatchNode, Sequence, Batch} ->
            {Accepted, Tracked} = track_batch(
                atom_to_binary(Node, utf8), BatchNode, Sequence, Batch, State
            ),
            Raw = case Accepted of true -> raw_events(Batch); false -> [] end,
            drain_single(
                Node, CaptureId, EndKind, EndDetail, [Raw | Acc], Tracked,
                ReplyReceipt, ReplyStatus, Deadline
            );
        {beamtrace_receipt, CaptureId, NodeBinary, Receipt, Status} ->
            FinalState = validate_receipt(NodeBinary, Receipt, Status, State),
            finish_verified(
                flatten(Acc), EndKind, EndDetail, FinalState, Receipt
            )
    after Remaining ->
        NodeBinary = atom_to_binary(Node, utf8),
        FinalState = validate_receipt(
            NodeBinary, ReplyReceipt, ReplyStatus,
            add_issue(State, raw_issue(
                <<"drain_timeout">>, NodeBinary, <<>>, 0, drain_timeout(State)
            ))
        ),
        finish_verified(flatten(Acc), EndKind, EndDetail, FinalState, ReplyReceipt)
    end.

validate_receipt(NodeBinary, Receipt, Status, State) ->
    Checks = [
        {<<"final_batch_sequence">>, maps:get(last_sequence, State, 0),
            maps:get(final_batch_sequence, Receipt, -1)},
        {<<"event_count">>, maps:get(event_count, State, 0),
            maps:get(event_count, Receipt, -1)},
        {<<"byte_count">>, maps:get(byte_count, State, 0),
            maps:get(byte_count, Receipt, -1)}
    ],
    Checked = lists:foldl(fun({Field, Expected, Actual}, Acc) ->
        case Expected =:= Actual of
            true -> Acc;
            false -> add_issue(Acc, raw_issue(
                <<"receipt_mismatch">>, NodeBinary, Field, Expected, Actual
            ))
        end
    end, State, Checks),
    case Status of
        verified -> Checked;
        drain_timeout -> add_issue(Checked, raw_issue(
            <<"drain_timeout">>, NodeBinary, <<>>, 0, drain_timeout(State)
        ));
        _ -> add_issue(Checked, raw_issue(
            <<"legacy_unverified">>, NodeBinary, <<"unknown_seal_status">>, 0, 0
        ))
    end.

finish_verified(Events, EndKind, EndDetail, State, Receipt) ->
    NodeBinary = maps:get(node, Receipt, <<"unknown@node">>),
    RawReceipt = {raw_node_receipt,
        NodeBinary,
        maps:get(final_batch_sequence, Receipt, 0),
        maps:get(event_count, Receipt, 0),
        maps:get(byte_count, Receipt, 0)},
    Origin = maps:get(origin_local_ns, Receipt, 0),
    Calibration = {clock_calibration, 0, [
        {node_clock, NodeBinary, Origin, none, none}
    ]},
    Outcome = {raw_outcome, EndKind, EndDetail,
        lists:reverse(maps:get(issues, State, [])), [RawReceipt]},
    {ok, {Events, Outcome, Calibration}}.

finish_unsealed(Events, EndKind, EndDetail, State) ->
    Outcome = {raw_outcome, EndKind, EndDetail,
        lists:reverse(maps:get(issues, State, [])), []},
    {ok, {Events, Outcome, {clock_calibration, 0, []}}}.

clock_probe_phase(Nodes) ->
    Parent = self(),
    Reference = make_ref(),
    Anchor = erlang:system_time(nanosecond),
    Deadline = erlang:monotonic_time(millisecond) + 2000,
    _ = [spawn(fun() ->
        Parent ! {beamtrace_clock_probe, Reference, Node,
            best_clock_sample(Node, Deadline, 7, none)}
    end) || Node <- Nodes],
    {Anchor, gather_clock_samples(Reference, Nodes, Deadline, #{})}.

gather_clock_samples(_Reference, [], _Deadline, Acc) -> Acc;
gather_clock_samples(Reference, Pending, Deadline, Acc) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {beamtrace_clock_probe, Reference, Node, Sample} ->
            gather_clock_samples(
                Reference,
                lists:delete(Node, Pending),
                Deadline,
                maps:put(Node, Sample, Acc)
            )
    after Remaining -> Acc
    end.

best_clock_sample(_Node, _Deadline, 0, Best) -> Best;
best_clock_sample(Node, Deadline, Remaining, Best) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> Best;
        false ->
            Sample = clock_sample(Node),
            best_clock_sample(
                Node,
                Deadline,
                Remaining - 1,
                minimum_rtt_sample(Best, Sample)
            )
    end.

clock_sample(Node) ->
    StartedMono = erlang:monotonic_time(nanosecond),
    StartedUnix = erlang:system_time(nanosecond),
    try erpc:call(Node, erlang, monotonic_time, [nanosecond], 500) of
        Local when is_integer(Local) ->
            FinishedMono = erlang:monotonic_time(nanosecond),
            FinishedUnix = erlang:system_time(nanosecond),
            Rtt = erlang:max(0, FinishedMono - StartedMono),
            {some, {clock_sample,
                Local,
                StartedUnix + (FinishedUnix - StartedUnix) div 2,
                (Rtt + 1) div 2,
                Rtt}}
    catch
        _:_ -> none
    end.

minimum_rtt_sample(none, Sample) -> Sample;
minimum_rtt_sample(Best, none) -> Best;
minimum_rtt_sample({some, {clock_sample, _, _, _, BestRtt}} = Best,
                   {some, {clock_sample, _, _, _, CandidateRtt}} = Candidate) ->
    case CandidateRtt < BestRtt of
        true -> Candidate;
        false -> Best
    end.

attach_clock_phases({ok, {Events, Outcome, {clock_calibration, _OldAnchor, Nodes}}},
                    {Anchor, Before}, {_AfterAnchor, After}) ->
    CalibratedNodes = [
        {node_clock, NodeBinary, Origin,
            maps:get(binary_to_atom(NodeBinary, utf8), Before, none),
            maps:get(binary_to_atom(NodeBinary, utf8), After, none)}
        || {node_clock, NodeBinary, Origin, _OldBefore, _OldAfter} <- Nodes
    ],
    {ok, {Events, Outcome, {clock_calibration, Anchor, CalibratedNodes}}};
attach_clock_phases(Error, _Before, _After) -> Error.

initial_batch_credits() ->
    'beamtrace_runtime@credit_policy':initial_window().

refill_batch_count() ->
    'beamtrace_runtime@credit_policy':refill_batch_count().

replenish_multi_credit(Batch, Prepared, CreditDebt) ->
    case batch_node(Batch) of
        {ok, NodeBinary} ->
            case prepared_agent(NodeBinary, Prepared) of
                {ok, Node, Agent} ->
                    Debt = maps:get(Node, CreditDebt, 0) + 1,
                    case replenish_credit(Node, Agent, Debt) of
                        {ok, NextDebt} ->
                            {ok, maps:put(Node, NextDebt, CreditDebt)};
                        {error, Reason} -> {error, Reason}
                    end;
                error -> {error, unknown_batch_node}
            end;
        error -> {error, missing_batch_node}
    end.

batch_node([#{node := Node} | _]) when is_binary(Node) -> {ok, Node};
batch_node([_Invalid | Rest]) -> batch_node(Rest);
batch_node([]) -> error.

prepared_agent(_NodeBinary, []) -> error;
prepared_agent(NodeBinary, [{Node, _Digest, Agent, _Disposition} | Rest]) ->
    case atom_to_binary(Node, utf8) =:= NodeBinary of
        true -> {ok, Node, Agent};
        false -> prepared_agent(NodeBinary, Rest)
    end.

wait_time(Now, Deadline, IdleDeadline, true) when is_integer(IdleDeadline) ->
    erlang:max(0, erlang:min(Deadline, IdleDeadline) - Now);
wait_time(Now, Deadline, _IdleDeadline, _SeenRoot) ->
    erlang:max(0, Deadline - Now).

raw_events(Events) ->
    [raw_event(Event) || Event <- Events, is_map(Event), maps:is_key(kind, Event)].

raw_event(Event) ->
    Kind = maps:get(kind, Event),
    Process = maps:get(process, Event, #{}),
    Physical = maps:get(physical, Process, #{}),
    Metadata = maps:get(metadata, Process, #{}),
    Peer = peer_view(Kind, Event),
    {raw_event_v2,
        as_binary(maps:get(id, Event, <<"event-unknown">>)),
        as_binary(maps:get(root_id, Event, <<"root-unknown">>)),
        as_binary(maps:get(node, Event, <<"unknown@node">>)),
        as_binary(maps:get(pid, Physical, <<"<unknown>">>)),
        maps:get(local_offset_ns, Event, 0),
        maps:get(local_order, Event, 0),
        atom_binary(Kind),
        as_binary(maps:get(node, Peer, <<>>)),
        as_binary(maps:get(pid, Peer, <<>>)),
        integer_value(maps:get(previous_serial, Event, 0)),
        integer_value(maps:get(serial, Event, 0)),
        atom_binary(maps:get(semantic, Event, Kind)),
        raw_process_metadata(Metadata),
        raw_term_view(event_term(Kind, Event))}.

event_term(root, Event) -> maps:get(arguments, Event, #{});
event_term(send, Event) -> maps:get(message, Event, #{});
event_term('receive', Event) -> maps:get(message, Event, #{});
event_term(print, Event) -> maps:get(message, Event, #{});
event_term(exit, Event) -> maps:get(reason, Event, #{});
event_term(_Kind, _Event) -> #{}.

raw_term_view(Value) -> raw_term_view(Value, 0).

raw_term_view(_Value, Depth) when Depth > 64 ->
    {raw_redacted, <<"wire_depth_limit">>};
raw_term_view(#{kind := atom} = Value, _Depth) ->
    {raw_atom, metadata_text(maps:get(tag, Value, <<>>))};
raw_term_view(#{kind := tuple} = Value, Depth) ->
    Items = maps:get(items, Value, []),
    {raw_tuple,
        integer_value(maps:get(size, Value, length(Items))),
        raw_term_items(Items, Depth + 1)};
raw_term_view(#{kind := list} = Value, Depth) ->
    Items = maps:get(items, Value, []),
    {raw_list,
        integer_value(maps:get(length, Value, length(Items))),
        raw_term_items(Items, Depth + 1)};
raw_term_view(#{kind := map} = Value, Depth) ->
    Entries = maps:get(entries, Value, []),
    {raw_map,
        integer_value(maps:get(size, Value, length(Entries))),
        raw_term_entries(Entries, Depth + 1)};
raw_term_view(#{kind := binary} = Value, _Depth) ->
    {raw_binary,
        integer_value(maps:get(bytes, Value, 0)),
        display_text(maps:get(value, Value, undefined)),
        metadata_text(maps:get(fingerprint, Value, undefined))};
raw_term_view(#{kind := scalar} = Value, _Depth) ->
    {raw_scalar,
        metadata_text(maps:get(type, Value, other)),
        display_text(maps:get(value, Value, undefined)),
        metadata_text(maps:get(fingerprint, Value, undefined))};
raw_term_view(#{kind := redacted} = Value, _Depth) ->
    {raw_redacted, metadata_text(maps:get(reason, Value, policy))};
raw_term_view(_Value, _Depth) -> raw_hidden.

raw_term_items(Items, Depth) when is_list(Items) ->
    [raw_term_view(Item, Depth) || Item <- lists:sublist(Items, 32)];
raw_term_items(_Items, _Depth) -> [].

raw_term_entries(Entries, Depth) when is_list(Entries) ->
    [
        {raw_term_view(maps:get(key, Entry, #{}), Depth),
         raw_term_view(maps:get(value, Entry, #{}), Depth)}
        || Entry <- lists:sublist(Entries, 32), is_map(Entry)
    ];
raw_term_entries(_Entries, _Depth) -> [].

display_text(undefined) -> <<>>;
display_text(Value) when is_binary(Value) -> Value;
display_text(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
display_text(Value) when is_integer(Value) -> integer_to_binary(Value);
display_text(Value) when is_float(Value) -> float_to_binary(Value, [short]);
display_text(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value)
    catch _:_ -> <<>>
    end;
display_text(_Value) -> <<>>.

raw_process_metadata(Metadata) when is_map(Metadata) ->
    {InitialModule, InitialFunction, InitialArity} =
        initial_call_parts(maps:get(initial_call, Metadata, undefined)),
    {raw_process_metadata,
        metadata_text(maps:get(registered_name, Metadata, undefined)),
        metadata_text(maps:get(process_label, Metadata, undefined)),
        InitialModule,
        InitialFunction,
        InitialArity,
        stable_ancestors(maps:get(ancestors, Metadata, [])),
        metadata_text(maps:get(supervisor_child_id, Metadata, undefined))};
raw_process_metadata(_Metadata) ->
    {raw_process_metadata, <<>>, <<>>, <<>>, <<>>, -1, [], <<>>}.

initial_call_parts({Module, Function, Arity})
        when is_atom(Module), is_atom(Function), is_integer(Arity), Arity >= 0 ->
    {metadata_text(Module), metadata_text(Function), Arity};
initial_call_parts(_InitialCall) -> {<<>>, <<>>, -1}.

stable_ancestors(Ancestors) when is_list(Ancestors) ->
    lists:sublist(stable_ancestor_texts(Ancestors), 32);
stable_ancestors(_Ancestors) -> [].

stable_ancestor_texts([]) -> [];
stable_ancestor_texts([Ancestor | Rest]) ->
    case metadata_text(Ancestor) of
        <<>> -> stable_ancestor_texts(Rest);
        Text -> [Text | stable_ancestor_texts(Rest)]
    end.

metadata_text(undefined) -> <<>>;
metadata_text([]) -> <<>>;
metadata_text(Value) when is_atom(Value) -> bounded_metadata_binary(atom_to_binary(Value, utf8));
metadata_text(Value) when is_binary(Value) -> bounded_metadata_binary(Value);
metadata_text(Value) when is_list(Value) ->
    try bounded_metadata_binary(unicode:characters_to_binary(Value))
    catch _:_ -> <<>>
    end;
metadata_text(_Value) -> <<>>.

bounded_metadata_binary(Value) when byte_size(Value) =< 256 -> Value;
bounded_metadata_binary(_Value) -> <<>>.

peer_view(send, Event) -> maps:get(to, Event, #{});
peer_view('receive', Event) -> maps:get(from, Event, #{});
peer_view(spawn, Event) -> maps:get(child, Event, #{});
peer_view(link, Event) -> maps:get(peer, Event, #{});
peer_view(_Kind, _Event) -> #{}.

is_root({raw_event_v2, _Id, _Root, _Node, _Pid, _At, _Order, <<"root">>,
        _PN, _PP, _Previous, _Current, _Semantic, _Metadata, _Term}) ->
    true;
is_root({raw_event_with_metadata, _Id, _Root, _Node, _Pid, _At, <<"root">>,
        _PN, _PP, _Serial, _Semantic, _Metadata}) ->
    true;
is_root({raw_event, _Id, _Root, _Node, _Pid, _At, <<"root">>, _PN, _PP, _Serial, _Semantic}) ->
    true;
is_root(_Event) -> false.

flatten(Acc) -> lists:append(lists:reverse(Acc)).

connect_hidden(Node, Cookie) ->
    case ensure_distribution(Node) of
        ok ->
            true = erlang:set_cookie(Node, Cookie),
            connection_manager_call({acquire, Node});
        Error -> Error
    end.

maybe_disconnect(Node, {connection_lease, Lease}) ->
    connection_manager_call({release, Node, Lease});
maybe_disconnect(_Node, _InvalidLease) -> ok.

connection_manager_call(Request) ->
    Manager = ensure_connection_manager(),
    Reference = make_ref(),
    Monitor = erlang:monitor(process, Manager),
    Manager ! {connection_call, self(), Reference, Request},
    receive
        {connection_reply, Reference, Reply} ->
            erlang:demonitor(Monitor, [flush]),
            Reply;
        {'DOWN', Monitor, process, Manager, Reason} ->
            {error, {connection_manager_down, Reason}}
    after 15000 ->
        erlang:demonitor(Monitor, [flush]),
        {error, connection_manager_timeout}
    end.

ensure_connection_manager() ->
    case whereis(beamtrace_connection_manager) of
        undefined -> start_connection_manager();
        Pid when is_pid(Pid) -> Pid
    end.

start_connection_manager() ->
    Candidate = spawn(fun() -> connection_manager_loop(#{} ) end),
    try register(beamtrace_connection_manager, Candidate) of
        true -> Candidate
    catch
        error:badarg ->
            exit(Candidate, kill),
            ensure_connection_manager()
    end.

connection_manager_loop(State) ->
    receive
        {connection_call, Caller, Reference, {acquire, Node}} ->
            {Reply, NextState} = acquire_connection(Node, State),
            Caller ! {connection_reply, Reference, Reply},
            connection_manager_loop(NextState);
        {connection_call, Caller, Reference, {release, Node, Lease}} ->
            {Reply, NextState} = release_connection(Node, Lease, State),
            Caller ! {connection_reply, Reference, Reply},
            connection_manager_loop(NextState);
        _Other -> connection_manager_loop(State)
    end.

acquire_connection(Node, State) ->
    Lease = make_ref(),
    case maps:get(Node, State, undefined) of
        {Owned, Leases} ->
            {{ok, {connection_lease, Lease}}, State#{Node => {Owned, [Lease | Leases]}}};
        undefined ->
            AlreadyConnected = lists:member(Node, nodes(connected)),
            case AlreadyConnected orelse net_kernel:connect_node(Node) =:= true of
                true ->
                    Owned = not AlreadyConnected,
                    {{ok, {connection_lease, Lease}}, State#{Node => {Owned, [Lease]}}};
                false -> {{error, node_unreachable}, State}
            end
    end.

release_connection(Node, Lease, State) ->
    case maps:get(Node, State, undefined) of
        undefined -> {ok, State};
        {Owned, Leases} ->
            Remaining = lists:delete(Lease, Leases),
            case length(Remaining) =:= length(Leases) of
                true -> {ok, State};
                false ->
                    case Remaining of
                        [] ->
                            _ = case Owned of
                                true -> erlang:disconnect_node(Node);
                                false -> ok
                            end,
                            {ok, maps:remove(Node, State)};
                        _ -> {ok, State#{Node => {Owned, Remaining}}}
                    end
            end
    end.

ensure_distribution(Node) ->
    case node() of
        nonode@nohost ->
            Domain = name_domain(Node),
            case net_kernel:start(undefined, #{
                name_domain => Domain,
                dist_listen => false,
                hidden => true
            }) of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                {error, Reason} -> {error, {distribution_start_failed, Reason}}
            end;
        _ -> ok
    end.

name_domain(Node) ->
    [_Name, Host] = string:split(atom_to_list(Node), "@", all),
    case lists:member($., Host) of
        true -> longnames;
        false -> shortnames
    end.

validate_inputs(Node, Cookie, Module, Function, Arity, Window)
        when is_binary(Node), byte_size(Node) > 2, byte_size(Node) =< 255,
             is_binary(Cookie), byte_size(Cookie) > 0, byte_size(Cookie) =< 255,
             is_binary(Module), byte_size(Module) > 0, byte_size(Module) =< 255,
             is_binary(Function), byte_size(Function) > 0, byte_size(Function) =< 255,
             is_integer(Arity), Arity >= 0, Arity =< 255,
             is_integer(Window), Window > 0 ->
    case binary:matches(Node, <<"@">>) of
        [_] -> ok;
        _ -> {error, invalid_node_name}
    end;
validate_inputs(_Node, _Cookie, _Module, _Function, _Arity, _Window) ->
    {error, invalid_capture_arguments}.

validate_node_cookie(Node, Cookie)
        when is_binary(Node), byte_size(Node) > 2, byte_size(Node) =< 255,
             is_binary(Cookie), byte_size(Cookie) > 0, byte_size(Cookie) =< 255 ->
    case binary:matches(Node, <<"@">>) of
        [_] -> ok;
        _ -> {error, invalid_node_name}
    end;
validate_node_cookie(_Node, _Cookie) ->
    {error, invalid_attach_arguments}.

capture_options(MaxRoots, DrainTimeoutMs, Predicate, Privacy, Preset)
        when is_integer(MaxRoots), MaxRoots > 0, MaxRoots =< 1000,
             is_integer(DrainTimeoutMs), DrainTimeoutMs >= 1000,
             DrainTimeoutMs =< 60000 ->
    case {
        normalize_root_filter(Predicate, 0),
        normalize_privacy(Privacy),
        normalize_preset(Preset)
    } of
        {{ok, RootFilter}, {ok, PrivacyOptions}, {ok, NormalizedPreset}} ->
            {ok, #{
                max_roots => MaxRoots,
                drain_timeout_ms => DrainTimeoutMs,
                root_filter => RootFilter,
                privacy => PrivacyOptions,
                preset => NormalizedPreset
            }};
        {{error, Reason}, _, _} -> {error, Reason};
        {_, {error, Reason}, _} -> {error, Reason};
        {_, _, {error, Reason}} -> {error, Reason}
    end;
capture_options(MaxRoots, _DrainTimeoutMs, _Predicate, _Privacy, _Preset)
        when not is_integer(MaxRoots); MaxRoots =< 0; MaxRoots > 1000 ->
    {error, invalid_root_budget};
capture_options(_MaxRoots, _DrainTimeoutMs, _Predicate, _Privacy, _Preset) ->
    {error, invalid_drain_timeout}.

normalize_root_filter(_Predicate, Depth) when Depth > 32 ->
    {error, root_filter_too_deep};
normalize_root_filter(agent_always, _Depth) -> {ok, all};
normalize_root_filter(agent_never, _Depth) -> {ok, never};
normalize_root_filter({agent_arg_tag, Index, Comparator, Tag}, _Depth)
        when is_integer(Index), Index >= 0,
             is_binary(Tag), byte_size(Tag) > 0, byte_size(Tag) =< 255 ->
    case normalize_agent_comparator(Comparator) of
        {ok, Normalized} -> {ok, {arg_tag, Index, Normalized, Tag}};
        Error -> Error
    end;
normalize_root_filter({agent_arg_type, Index, Comparator, Kind}, _Depth)
        when is_integer(Index), Index >= 0,
             is_binary(Kind), byte_size(Kind) > 0, byte_size(Kind) =< 32 ->
    case normalize_agent_comparator(Comparator) of
        {ok, Normalized} ->
            {ok, {arg_type, Index, Normalized, string:lowercase(Kind)}};
        Error -> Error
    end;
normalize_root_filter({agent_and, Left, Right}, Depth) ->
    normalize_binary_filter('and', Left, Right, Depth);
normalize_root_filter({agent_or, Left, Right}, Depth) ->
    normalize_binary_filter('or', Left, Right, Depth);
normalize_root_filter({agent_not, Predicate}, Depth) ->
    case normalize_root_filter(Predicate, Depth + 1) of
        {ok, Normalized} -> {ok, {'not', Normalized}};
        Error -> Error
    end;
normalize_root_filter(_Predicate, _Depth) ->
    {error, invalid_root_filter}.

normalize_binary_filter(Operator, Left, Right, Depth) ->
    case {
        normalize_root_filter(Left, Depth + 1),
        normalize_root_filter(Right, Depth + 1)
    } of
        {{ok, NormalizedLeft}, {ok, NormalizedRight}} ->
            {ok, {Operator, NormalizedLeft, NormalizedRight}};
        {{error, Reason}, _} -> {error, Reason};
        {_, {error, Reason}} -> {error, Reason}
    end.

normalize_agent_comparator(agent_equal) -> {ok, equal};
normalize_agent_comparator(agent_not_equal) -> {ok, not_equal};
normalize_agent_comparator(_Comparator) -> {error, invalid_root_comparator}.

normalize_privacy(metadata) -> {ok, #{mode => metadata}};
normalize_privacy({raw, {raw_policy, Keys, MaxDepth, MaxBinaryBytes}})
        when is_list(Keys), length(Keys) > 0, length(Keys) =< 128,
             is_integer(MaxDepth), MaxDepth > 0, MaxDepth =< 32,
             is_integer(MaxBinaryBytes), MaxBinaryBytes > 0,
             MaxBinaryBytes =< 1048576 ->
    case lists:all(fun valid_redact_key/1, Keys) of
        true ->
            {ok, #{
                mode => raw,
                redact_keys => Keys,
                max_depth => MaxDepth,
                max_binary_bytes => MaxBinaryBytes
            }};
        false -> {error, invalid_redact_key}
    end;
normalize_privacy(_Privacy) -> {error, invalid_privacy_policy}.

valid_redact_key(Key) ->
    is_binary(Key) andalso byte_size(Key) > 0 andalso byte_size(Key) =< 256.

normalize_preset(Preset) when
        Preset =:= generic;
        Preset =:= gleam_actor;
        Preset =:= wisp_mist;
        Preset =:= gen_server;
        Preset =:= phoenix;
        Preset =:= erlang_supervisor ->
    {ok, Preset};
normalize_preset(_Preset) -> {error, invalid_capture_preset}.

positive(Value, _Default) when is_integer(Value), Value > 0 -> Value;
positive(_Value, Default) -> Default.

capture_id() ->
    <<"capture-", (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.

as_binary(Value) when is_binary(Value) -> Value;
as_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
as_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
as_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
as_binary(Value) -> unicode:characters_to_binary(io_lib:format("~0p", [Value])).

atom_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
atom_binary(Value) -> as_binary(Value).

integer_value(Value) when is_integer(Value) -> Value;
integer_value(_Value) -> 0.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason_binary(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
