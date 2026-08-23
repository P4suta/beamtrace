%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_capture_ffi).

-export([
    collect_remote/9,
    collect_remote_spec/13,
    collect_distributed/9,
    collect_distributed_spec/13,
    probe_remote/2,
    sample_remote/4,
    search_remote/4,
    wait_remote_armed/3,
    wait_remote_available/3
]).

-define(IDLE_AFTER_ROOT_MS, 250).
-define(DISTRIBUTED_IDLE_AFTER_ROOT_MS, 1000).
-define(INITIAL_BATCH_CREDITS, 1024).
-define(CREDIT_REPLENISH_AT, 512).

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
    case {validate_distributed_inputs(
        NodeBinaries,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs
    ), capture_options(MaxRoots, Predicate, Privacy, Preset)} of
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
    Label = 1 + (binary:decode_unsigned(crypto:strong_rand_bytes(4)) rem 134217726),
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
            try setup_distributed(Prepared, MFA, Label, CaptureId, WindowMs)
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

setup_distributed(Prepared, MFA, Label, CaptureId, WindowMs) ->
    case grant_all(Prepared) of
        ok ->
            Root = hd(Prepared),
            Passives = tl(Prepared),
            case listen_all(Passives, Label) of
                ok ->
                    {RootNode, _RootDigest, RootAgent, _RootDisposition} = Root,
                    case beamtrace_relay:arm_agent(RootNode, RootAgent, MFA) of
                        {ok, armed} ->
                            Nodes = [Node || {Node, _Digest, _Agent, _Disposition} <- Prepared],
                            monitor_nodes(Nodes, true),
                            try
                                Deadline = erlang:monotonic_time(millisecond) + WindowMs,
                                collect_batches_multi(
                                    Nodes,
                                    Prepared,
                                    CaptureId,
                                    Deadline,
                                    undefined,
                                    false,
                                    [],
                                    [],
                                    #{}
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
    case beamtrace_relay:grant(Node, Agent, ?INITIAL_BATCH_CREDITS) of
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
        true -> finish_collect_multi(SeenRoot, Acc, Missing);
        false ->
            receive
                beamtrace_cancel ->
                    {ok, {flatten(Acc), <<"truncated:cancelled">>}};
                {beamtrace_batch, CaptureId, _Sequence, Batch} ->
                    Raw = raw_events(Batch),
                    HasRoot = lists:any(fun is_root/1, Raw),
                    Seen = SeenRoot orelse HasRoot,
                    case replenish_multi_credit(Batch, Prepared, CreditDebt) of
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
                            {ok, {flatten([Raw | Acc]),
                                <<"truncated:credit_replenish_failed">>}}
                    end;
                {beamtrace_stop, CaptureId, {truncated, Reason}} ->
                    {ok, {flatten(Acc), <<"truncated:", (atom_binary(Reason))/binary>>}};
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
                finish_collect_multi(SeenRoot, Acc, Missing)
            end
    end.

finish_collect_multi(_SeenRoot, Acc, [Missing | _]) ->
    {ok, {flatten(Acc), <<"partial_node:", (atom_to_binary(Missing, utf8))/binary>>}};
finish_collect_multi(true, Acc, []) -> {ok, {flatten(Acc), <<"complete">>}};
finish_collect_multi(false, _Acc, []) -> {error, <<"trigger_timeout">>}.

cleanup_prepared(Prepared) ->
    lists:foreach(fun({Node, Digest, Agent, Disposition}) ->
        _ = beamtrace_relay:stop_agent(Node, Agent),
        _ = maybe_unload(Node, Digest, Agent, Disposition),
        ok
    end, Prepared),
    ok.

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
    case {validate_inputs(
        NodeBinary,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs
    ), capture_options(MaxRoots, Predicate, Privacy, Preset)} of
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
                case beamtrace_relay:grant(Node, Agent, ?INITIAL_BATCH_CREDITS) of
                    ok ->
                        case beamtrace_relay:arm_agent(Node, Agent, MFA) of
                            {ok, armed} ->
                                monitor_node(Node, true),
                                Deadline = erlang:monotonic_time(millisecond) + WindowMs,
                                collect_batches(
                                    Node,
                                    Agent,
                                    CaptureId,
                                    Deadline,
                                    undefined,
                                    false,
                                    [],
                                    0
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

collect_batches(Node, Agent, CaptureId, Deadline, IdleDeadline, SeenRoot, Acc, CreditDebt) ->
    Now = erlang:monotonic_time(millisecond),
    Wait = wait_time(Now, Deadline, IdleDeadline, SeenRoot),
    case Wait =< 0 of
        true -> finish_collect(SeenRoot, Acc);
        false ->
            receive
                beamtrace_cancel ->
                    {ok, {flatten(Acc), <<"truncated:cancelled">>}};
                {beamtrace_batch, CaptureId, _Sequence, Batch} ->
                    Raw = raw_events(Batch),
                    HasRoot = lists:any(fun is_root/1, Raw),
                    Seen = SeenRoot orelse HasRoot,
                    case replenish_credit(Node, Agent, CreditDebt + 1) of
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
                                NextDebt
                            );
                        {error, _Reason} ->
                            {ok, {flatten([Raw | Acc]),
                                <<"truncated:credit_replenish_failed">>}}
                    end;
                {beamtrace_stop, CaptureId, {truncated, Reason}} ->
                    {ok, {flatten(Acc), <<"truncated:", (atom_binary(Reason))/binary>>}};
                {nodedown, Node} ->
                    {ok, {flatten(Acc), <<"partial_node:", (atom_to_binary(Node, utf8))/binary>>}};
                _Other ->
                    collect_batches(
                        Node,
                        Agent,
                        CaptureId,
                        Deadline,
                        IdleDeadline,
                        SeenRoot,
                        Acc,
                        CreditDebt
                    )
            after Wait ->
                finish_collect(SeenRoot, Acc)
            end
    end.

finish_collect(true, Acc) -> {ok, {flatten(Acc), <<"complete">>}};
finish_collect(false, _Acc) -> {error, <<"trigger_timeout">>}.

replenish_credit(Node, Agent, Debt) when Debt >= ?CREDIT_REPLENISH_AT ->
    case beamtrace_relay:grant(Node, Agent, Debt) of
        ok -> {ok, 0};
        {error, Reason} -> {error, Reason}
    end;
replenish_credit(_Node, _Agent, Debt) ->
    {ok, Debt}.

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
    {raw_event_with_term,
        as_binary(maps:get(id, Event, <<"event-unknown">>)),
        as_binary(maps:get(root_id, Event, <<"root-unknown">>)),
        as_binary(maps:get(node, Event, <<"unknown@node">>)),
        as_binary(maps:get(pid, Physical, <<"<unknown>">>)),
        maps:get(local_timestamp_ns, Event, 0),
        atom_binary(Kind),
        as_binary(maps:get(node, Peer, <<>>)),
        as_binary(maps:get(pid, Peer, <<>>)),
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

is_root({raw_event_with_term, _Id, _Root, _Node, _Pid, _At, <<"root">>,
        _PN, _PP, _Serial, _Semantic, _Metadata, _Term}) ->
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

capture_options(MaxRoots, Predicate, Privacy, Preset)
        when is_integer(MaxRoots), MaxRoots > 0, MaxRoots =< 1000 ->
    case {
        normalize_root_filter(Predicate, 0),
        normalize_privacy(Privacy),
        normalize_preset(Preset)
    } of
        {{ok, RootFilter}, {ok, PrivacyOptions}, {ok, NormalizedPreset}} ->
            {ok, #{
                max_roots => MaxRoots,
                root_filter => RootFilter,
                privacy => PrivacyOptions,
                preset => NormalizedPreset
            }};
        {{error, Reason}, _, _} -> {error, Reason};
        {_, {error, Reason}, _} -> {error, Reason};
        {_, _, {error, Reason}} -> {error, Reason}
    end;
capture_options(_MaxRoots, _Predicate, _Privacy, _Preset) ->
    {error, invalid_root_budget}.

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
