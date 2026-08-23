%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_capture_ffi).

-export([collect_remote/9, collect_distributed/9, probe_remote/2, sample_remote/4]).

-define(IDLE_AFTER_ROOT_MS, 250).
-define(DISTRIBUTED_IDLE_AFTER_ROOT_MS, 1000).

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
    case validate_distributed_inputs(
        NodeBinaries,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs
    ) of
        ok ->
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
                            MaxAgentMailbox
                        )
                    after
                        disconnect_owned(Connections)
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

run_distributed(
    Connections,
    MFA,
    WindowMs,
    MaxEvents,
    MaxBytes,
    MaxAgentMailbox
) ->
    CaptureId = capture_id(),
    %% Keep labels inside the historical immediate-integer range. This is
    %% understood by every supported distribution peer and avoids silently
    %% dropping a token when mixed runtimes negotiate conservative encoding.
    Label = 1 + (binary:decode_unsigned(crypto:strong_rand_bytes(4)) rem 134217726),
    Options = #{
        capture_id => CaptureId,
        trace_label => Label,
        mode => exact,
        max_events => positive(MaxEvents, 100000),
        max_bytes => positive(MaxBytes, 64000000),
        max_agent_mailbox => positive(MaxAgentMailbox, 10000),
        max_duration_ms => positive(WindowMs, 30000),
        batch_size => 128
    },
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
        {ok, _Disposition, Digest} ->
            case beamtrace_relay:start_agent(Node, self(), Options) of
                {ok, Agent} ->
                    prepare_nodes(Rest, Options, [{Node, Digest, Agent} | Accumulator]);
                {error, Reason} ->
                    _ = beamtrace_relay:unload_unstarted(Node, Digest),
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
                    {RootNode, _RootDigest, RootAgent} = Root,
                    case beamtrace_relay:arm_agent(RootNode, RootAgent, MFA) of
                        {ok, armed} ->
                            Nodes = [Node || {Node, _Digest, _Agent} <- Prepared],
                            monitor_nodes(Nodes, true),
                            try
                                Deadline = erlang:monotonic_time(millisecond) + WindowMs,
                                collect_batches_multi(
                                    Nodes,
                                    CaptureId,
                                    Deadline,
                                    undefined,
                                    false,
                                    [],
                                    []
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
grant_all([{Node, _Digest, Agent} | Rest]) ->
    case beamtrace_relay:grant(Node, Agent, 1024) of
        ok -> grant_all(Rest);
        {error, Reason} -> {error, Reason}
    end.

listen_all([], _Label) -> ok;
listen_all([{Node, _Digest, Agent} | Rest], Label) ->
    case beamtrace_relay:listen_agent(Node, Agent, Label) of
        {ok, listening} -> listen_all(Rest, Label);
        {error, Reason} -> {error, Reason}
    end.

collect_batches_multi(Nodes, CaptureId, Deadline, IdleDeadline, SeenRoot, Acc, Missing) ->
    Now = erlang:monotonic_time(millisecond),
    Wait = wait_time(Now, Deadline, IdleDeadline, SeenRoot),
    case Wait =< 0 of
        true -> finish_collect_multi(SeenRoot, Acc, Missing);
        false ->
            receive
                {beamtrace_batch, CaptureId, _Sequence, Batch} ->
                    Raw = raw_events(Batch),
                    HasRoot = lists:any(fun is_root/1, Raw),
                    Seen = SeenRoot orelse HasRoot,
                    NewIdle = case Seen of
                        true -> erlang:monotonic_time(millisecond)
                            + ?DISTRIBUTED_IDLE_AFTER_ROOT_MS;
                        false -> undefined
                    end,
                    collect_batches_multi(
                        Nodes,
                        CaptureId,
                        Deadline,
                        NewIdle,
                        Seen,
                        [Raw | Acc],
                        Missing
                    );
                {beamtrace_stop, CaptureId, {truncated, Reason}} ->
                    {ok, {flatten(Acc), <<"truncated:", (atom_binary(Reason))/binary>>}};
                {nodedown, Node} ->
                    NextMissing = case lists:member(Node, Nodes) of
                        true -> lists:usort([Node | Missing]);
                        false -> Missing
                    end,
                    collect_batches_multi(
                        Nodes,
                        CaptureId,
                        Deadline,
                        IdleDeadline,
                        SeenRoot,
                        Acc,
                        NextMissing
                    );
                _Other ->
                    collect_batches_multi(
                        Nodes,
                        CaptureId,
                        Deadline,
                        IdleDeadline,
                        SeenRoot,
                        Acc,
                        Missing
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
    lists:foreach(fun({Node, Digest, Agent}) ->
        _ = beamtrace_relay:stop_agent(Node, Agent),
        _ = beamtrace_relay:unload(Node, Digest, Agent),
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
        optional_binary(maps:get(initial_call, Sample, undefined)),
        integer_value(maps:get(message_queue_len, Sample, 0)),
        integer_value(maps:get(memory, Sample, 0)),
        integer_value(maps:get(reductions, Sample, 0)),
        integer_value(maps:get(heap_size, Sample, 0)),
        integer_value(maps:get(total_heap_size, Sample, 0)),
        integer_value(maps:get(link_count, Sample, 0)),
        optional_binary(maps:get(status, Sample, undefined)),
        optional_binary(maps:get(current_function, Sample, undefined))}.

optional_binary(undefined) -> <<>>;
optional_binary(Value) -> as_binary(Value).

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
    case validate_inputs(
        NodeBinary,
        CookieBinary,
        ModuleBinary,
        FunctionBinary,
        Arity,
        CaptureWindowMs
    ) of
        ok ->
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
                        MaxAgentMailbox
                    )
                    after
                        _ = maybe_disconnect(Node, OwnsConnection)
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} ->
            {error, reason_binary(Reason)}
    end.

run_capture(Node, MFA, WindowMs, MaxEvents, MaxBytes, MaxAgentMailbox) ->
    case beamtrace_relay:inject(Node) of
        {ok, _Disposition, Digest} ->
            CaptureId = capture_id(),
            Options = #{
                capture_id => CaptureId,
                mode => exact,
                max_events => positive(MaxEvents, 100000),
                max_bytes => positive(MaxBytes, 64000000),
                max_agent_mailbox => positive(MaxAgentMailbox, 10000),
                max_duration_ms => positive(WindowMs, 30000),
                batch_size => 128
            },
            run_injected(Node, MFA, WindowMs, Digest, CaptureId, Options);
        {error, Reason} ->
            {error, reason_binary(Reason)}
    end.

run_injected(Node, MFA, WindowMs, Digest, CaptureId, Options) ->
    case beamtrace_relay:start_agent(Node, self(), Options) of
        {ok, Agent} ->
            try
                case beamtrace_relay:grant(Node, Agent, 1024) of
                    ok ->
                        case beamtrace_relay:arm_agent(Node, Agent, MFA) of
                            {ok, armed} ->
                                monitor_node(Node, true),
                                Deadline = erlang:monotonic_time(millisecond) + WindowMs,
                                collect_batches(
                                    Node,
                                    CaptureId,
                                    Deadline,
                                    undefined,
                                    false,
                                    []
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
                _ = beamtrace_relay:unload(Node, Digest, Agent)
            end;
        {error, Reason} ->
            _ = unload_without_agent(Node, Digest),
            {error, reason_binary(Reason)}
    end.

unload_without_agent(Node, Digest) ->
    beamtrace_relay:unload_unstarted(Node, Digest).

collect_batches(Node, CaptureId, Deadline, IdleDeadline, SeenRoot, Acc) ->
    Now = erlang:monotonic_time(millisecond),
    Wait = wait_time(Now, Deadline, IdleDeadline, SeenRoot),
    case Wait =< 0 of
        true -> finish_collect(SeenRoot, Acc);
        false ->
            receive
                {beamtrace_batch, CaptureId, _Sequence, Batch} ->
                    Raw = raw_events(Batch),
                    HasRoot = lists:any(fun is_root/1, Raw),
                    Seen = SeenRoot orelse HasRoot,
                    NewIdle = case Seen of
                        true -> erlang:monotonic_time(millisecond) + ?IDLE_AFTER_ROOT_MS;
                        false -> undefined
                    end,
                    collect_batches(
                        Node,
                        CaptureId,
                        Deadline,
                        NewIdle,
                        Seen,
                        [Raw | Acc]
                    );
                {beamtrace_stop, CaptureId, {truncated, Reason}} ->
                    {ok, {flatten(Acc), <<"truncated:", (atom_binary(Reason))/binary>>}};
                {nodedown, Node} ->
                    {ok, {flatten(Acc), <<"partial_node:", (atom_to_binary(Node, utf8))/binary>>}};
                _Other ->
                    collect_batches(
                        Node,
                        CaptureId,
                        Deadline,
                        IdleDeadline,
                        SeenRoot,
                        Acc
                    )
            after Wait ->
                finish_collect(SeenRoot, Acc)
            end
    end.

finish_collect(true, Acc) -> {ok, {flatten(Acc), <<"complete">>}};
finish_collect(false, _Acc) -> {error, <<"trigger_timeout">>}.

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
    {raw_event_with_metadata,
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
        raw_process_metadata(Metadata)}.

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
            case lists:member(Node, nodes(connected)) of
                true -> {ok, false};
                false ->
                    case net_kernel:connect_node(Node) of
                        true -> {ok, true};
                        false -> {error, node_unreachable};
                        ignored -> {error, distribution_not_started}
                    end
            end;
        Error -> Error
    end.

maybe_disconnect(Node, true) -> erlang:disconnect_node(Node);
maybe_disconnect(_Node, false) -> ok.

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
