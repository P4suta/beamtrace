%% SPDX-License-Identifier: Apache-2.0 OR MIT
%%
%% This module is intentionally dependency-free. The relay loads this single
%% BEAM onto an observed node with code:load_binary/3; no Gleam runtime or OTP
%% application is installed on the target.
-module(beamtrace_agent).
-behaviour(gen_server).

-export([
    start/2,
    start_link/2,
    arm/2,
    listen/2,
    grant/2,
    ingest/2,
    status/1,
    stop/1,
    version/0,
    semantic/2,
    shape_term/2,
    claim_system_tracer/1,
    release_system_tracer/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(PROTOCOL_VERSION, 1).
-define(MODULE_HASH, <<"b7a54d1c-beamtrace-agent-v2">>).
-define(DEFAULT_MAX_EVENTS, 100000).
-define(DEFAULT_MAX_BYTES, 64000000).
-define(DEFAULT_MAX_MAILBOX, 10000).
-define(DEFAULT_BATCH_SIZE, 128).
-define(DEFAULT_DURATION_MS, 30000).

-record(state, {
    owner,
    owner_monitor,
    capture_id,
    mode = exact,
    preset = generic,
    privacy = #{mode => metadata, salt => <<>>},
    max_events = ?DEFAULT_MAX_EVENTS,
    max_bytes = ?DEFAULT_MAX_BYTES,
    max_agent_mailbox = ?DEFAULT_MAX_MAILBOX,
    max_roots = 1,
    root_filter = all,
    max_duration_ms = ?DEFAULT_DURATION_MS,
    batch_size = ?DEFAULT_BATCH_SIZE,
    credits = 0,
    queue = {[], []},
    queued = 0,
    event_count = 0,
    byte_count = 0,
    batch_sequence = 0,
    dropped_live = 0,
    completeness = complete,
    session = undefined,
    trigger = undefined,
    label = undefined,
    root_count = 0,
    owns_system_tracer = false,
    armed = false,
    ttl_timer = undefined
}).

start_link(Owner, Options) when is_pid(Owner), is_map(Options) ->
    gen_server:start_link(?MODULE, {Owner, Options}, []).

%% Used by a short-lived erpc worker. The owner monitor, rather than a link to
%% that worker, governs the injected agent's lifetime.
start(Owner, Options) when is_pid(Owner), is_map(Options) ->
    gen_server:start(?MODULE, {Owner, Options}, []).

arm(Pid, MFA) when is_pid(Pid), is_tuple(MFA) ->
    gen_server:call(Pid, {arm, MFA}, 10000).

listen(Pid, Label) when is_pid(Pid), is_integer(Label), Label >= 0 ->
    gen_server:call(Pid, {listen, Label}, 10000).

grant(Pid, Credits) when is_pid(Pid), is_integer(Credits), Credits >= 0 ->
    gen_server:call(Pid, {grant, Credits}).

ingest(Pid, Event) when is_pid(Pid), is_map(Event) ->
    gen_server:call(Pid, {ingest, Event}).

status(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, status).

stop(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, stop, 10000).

version() ->
    #{
        protocol => ?PROTOCOL_VERSION,
        module_hash => ?MODULE_HASH,
        otp_minimum => 27
    }.

init({Owner, Options}) ->
    Monitor = erlang:monitor(process, Owner),
    CaptureId = maps:get(capture_id, Options, new_capture_id()),
    Privacy0 = maps:get(privacy, Options, #{}),
    Privacy = maps:merge(
        #{
            mode => metadata,
            salt => crypto:strong_rand_bytes(16),
            max_depth => 8,
            max_binary_bytes => 256,
            max_items => 32,
            redact_keys => default_redact_keys()
        },
        Privacy0
    ),
    {ok, #state{
        owner = Owner,
        owner_monitor = Monitor,
        capture_id = CaptureId,
        mode = maps:get(mode, Options, exact),
        preset = maps:get(preset, Options, generic),
        privacy = Privacy,
        max_events = positive_option(max_events, Options, ?DEFAULT_MAX_EVENTS),
        max_bytes = positive_option(max_bytes, Options, ?DEFAULT_MAX_BYTES),
        max_agent_mailbox = positive_option(
            max_agent_mailbox,
            Options,
            ?DEFAULT_MAX_MAILBOX
        ),
        max_roots = positive_option(max_roots, Options, 1),
        root_filter = maps:get(root_filter, Options, all),
        max_duration_ms = positive_option(
            max_duration_ms,
            Options,
            ?DEFAULT_DURATION_MS
        ),
        batch_size = positive_option(batch_size, Options, ?DEFAULT_BATCH_SIZE),
        label = maps:get(trace_label, Options, undefined),
        queue = queue:new()
    }}.

handle_call({arm, _MFA}, _From, State = #state{armed = true}) ->
    {reply, {error, already_armed}, State};
handle_call({listen, _Label}, _From, State = #state{armed = true}) ->
    {reply, {error, already_armed}, State};
handle_call({listen, Label}, _From, State) ->
    case listen_capture(Label, State) of
        {ok, ListeningState} -> {reply, {ok, listening}, ListeningState};
        {error, Reason, ErrorState} -> {reply, {error, Reason}, ErrorState}
    end;
handle_call({arm, MFA}, _From, State) ->
    case validate_mfa(MFA) of
        ok ->
            case arm_capture(MFA, State) of
                {ok, ArmedState} ->
                    {reply, {ok, armed}, ArmedState};
                {error, Reason, ErrorState} ->
                    {reply, {error, Reason}, ErrorState}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({grant, Credits}, _From, State) ->
    Flushed = flush(State#state{credits = State#state.credits + Credits}),
    {reply, ok, Flushed};
handle_call({ingest, _Event}, _From, State = #state{completeness = {truncated, Reason}}) ->
    {reply, {truncated, Reason}, State};
handle_call({ingest, Event}, _From, State) ->
    case accept_event(Event, State) of
        {ok, Accepted} ->
            {reply, queued, flush(Accepted)};
        {truncated, Reason, Truncated} ->
            {reply, {truncated, Reason}, Truncated}
    end;
handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% Meta trace with an additional match-spec message and timestamp.
handle_info(
    {trace_ts, Pid, call, {M, F, Args}, {beamtrace_root, Label}, Timestamp},
    State = #state{label = Label, trigger = {M, F, _}}
) ->
    {noreply, record_root(Pid, {M, F, Args}, Timestamp, State)};
%% Some OTP releases omit the additional match-spec message from the shape.
handle_info(
    {trace_ts, Pid, call, {M, F, Args}, Timestamp},
    State = #state{trigger = {M, F, _}, armed = true}
) ->
    {noreply, record_root(Pid, {M, F, Args}, Timestamp, State)};
handle_info(
    {trace, Pid, call, {M, F, Args}, {beamtrace_root, Label}},
    State = #state{label = Label, trigger = {M, F, _}}
) ->
    {noreply, record_root(Pid, {M, F, Args}, erlang:monotonic_time(nanosecond), State)};
handle_info({seq_trace, Label, Info, Timestamp}, State = #state{label = Label}) ->
    %% A sequential trace token can be inherited when the VM delivers trace
    %% information to a process tracer. Never let that token escape again in a
    %% credit batch to the relay, otherwise tracing the collector recursively
    %% creates an unbounded stream of BeamTrace's own control messages.
    _ = seq_trace:set_token([]),
    {noreply, record_seq_trace(Info, Timestamp, State)};
handle_info({seq_trace, Label, Info}, State = #state{label = Label}) ->
    _ = seq_trace:set_token([]),
    {noreply, record_seq_trace(Info, erlang:monotonic_time(nanosecond), State)};
handle_info(
    {trace_ts, Parent, spawn, Child, InitialCall, Timestamp},
    State
) ->
    {noreply, record_spawn(Parent, Child, InitialCall, Timestamp, State)};
handle_info({trace_ts, Process, exit, Reason, Timestamp}, State) ->
    {noreply, record_exit(Process, Reason, Timestamp, State)};
handle_info({trace_ts, Process, register, Name, Timestamp}, State) ->
    {noreply, record_register(Process, Name, Timestamp, State)};
handle_info({trace_ts, Process, link, Peer, Timestamp}, State) ->
    {noreply, record_link(Process, Peer, Timestamp, State)};
handle_info({trace, Parent, spawn, Child, InitialCall}, State) ->
    {noreply, record_spawn(
        Parent, Child, InitialCall, erlang:monotonic_time(nanosecond), State
    )};
handle_info({trace, Process, exit, Reason}, State) ->
    {noreply, record_exit(
        Process, Reason, erlang:monotonic_time(nanosecond), State
    )};
handle_info({trace, Process, register, Name}, State) ->
    {noreply, record_register(
        Process, Name, erlang:monotonic_time(nanosecond), State
    )};
handle_info({trace, Process, link, Peer}, State) ->
    {noreply, record_link(
        Process, Peer, erlang:monotonic_time(nanosecond), State
    )};
handle_info(capture_timeout, State) ->
    TimedOut = truncate_capture(duration_budget, State),
    {noreply, TimedOut};
handle_info({'DOWN', Reference, process, Owner, _Reason}, State = #state{
    owner = Owner,
    owner_monitor = Reference
}) ->
    {stop, normal, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = cleanup_capture(State),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

arm_capture(MFA = {Module, _Function, _Arity}, State) ->
    case otp_supported() of
        false ->
            {error, {unsupported_otp, erlang:system_info(otp_release)}, State};
        true ->
            case code:ensure_loaded(Module) of
                {module, Module} -> arm_loaded(MFA, State);
                {error, Reason} -> {error, {module_not_loaded, Reason}, State}
            end
    end.

arm_loaded(MFA, State) ->
    case claim_system_tracer(self()) of
        {error, Reason} ->
            {error, Reason, State};
        {ok, _Previous} ->
            try
                Session = trace:session_create(beamtrace_capture, self(), []),
                Label = capture_label(State),
                MatchSpec = root_match_spec(
                    Label,
                    element(3, MFA),
                    State#state.root_filter
                ),
                case trace:function(Session, MFA, MatchSpec, [meta]) of
                    0 ->
                        _ = trace:session_destroy(Session),
                        _ = release_system_tracer(self()),
                        {error, trigger_not_found, State};
                    _Count ->
                        Timer = erlang:send_after(
                            State#state.max_duration_ms,
                            self(),
                            capture_timeout
                        ),
                        {ok, State#state{
                            session = Session,
                            trigger = MFA,
                            label = Label,
                            owns_system_tracer = true,
                            armed = true,
                            ttl_timer = Timer
                        }}
                end
            catch
                Class:Reason:Stacktrace ->
                    _ = release_system_tracer(self()),
                    {error, {trace_setup_failed, Class, Reason, Stacktrace}, State}
            end
    end.

listen_capture(Label, State) when is_integer(Label), Label >= 0 ->
    case otp_supported() of
        false ->
            {error, {unsupported_otp, erlang:system_info(otp_release)}, State};
        true ->
            case claim_system_tracer(self()) of
                {error, Reason} -> {error, Reason, State};
                {ok, _Previous} ->
                    try
                        Session = trace:session_create(beamtrace_capture, self(), []),
                        Timer = erlang:send_after(
                            State#state.max_duration_ms,
                            self(),
                            capture_timeout
                        ),
                        {ok, State#state{
                            session = Session,
                            label = Label,
                            owns_system_tracer = true,
                            armed = true,
                            ttl_timer = Timer
                        }}
                    catch
                        Class:Reason:Stacktrace ->
                            _ = release_system_tracer(self()),
                            {error, {trace_setup_failed, Class, Reason, Stacktrace}, State}
                    end
            end
    end;
listen_capture(_Label, State) ->
    {error, invalid_trace_label, State}.

capture_label(#state{label = Label}) when is_integer(Label), Label >= 0 -> Label;
capture_label(_State) -> erlang:unique_integer([positive, monotonic]).

root_match_spec(Label, Arity, Filter) ->
    Actions = [
        {set_seq_token, label, Label},
        {set_seq_token, send, true},
        {set_seq_token, 'receive', true},
        {set_seq_token, print, true},
        {set_seq_token, monotonic_timestamp, true},
        {trace, [], [procs, set_on_spawn, monotonic_timestamp]},
        {message, {const, {beamtrace_root, Label}}}
    ],
    Variables = argument_variables(Arity),
    case root_filter_guard(Filter, Variables) of
        true -> [{Variables, [], Actions}];
        false -> [{Variables, [false], Actions}];
        Guard -> [{Variables, [Guard], Actions}]
    end.

argument_variables(Arity) when is_integer(Arity), Arity >= 0, Arity =< 255 ->
    [list_to_atom("$" ++ integer_to_list(Index)) || Index <- lists:seq(1, Arity)].

root_filter_guard(all, _Variables) -> true;
root_filter_guard(never, _Variables) -> false;
root_filter_guard({arg_tag, Index, Comparator, TagBinary}, Variables) ->
    case argument_variable(Index, Variables) of
        {ok, Variable} ->
            case existing_tag(TagBinary) of
                {ok, Tag} ->
                    Equal = {'orelse',
                        {'=:=', Variable, Tag},
                        {'andalso',
                            {is_tuple, Variable},
                            {'andalso',
                                {'>', {tuple_size, Variable}, 0},
                                {'=:=', {element, 1, Variable}, Tag}
                            }
                        }
                    },
                    compare_guard(Comparator, Equal);
                error -> false
            end;
        error -> false
    end;
root_filter_guard({arg_type, Index, Comparator, Kind}, Variables) ->
    case argument_variable(Index, Variables) of
        {ok, Variable} ->
            case type_guard(Kind, Variable) of
                {ok, Guard} -> compare_guard(Comparator, Guard);
                error -> false
            end;
        error -> false
    end;
root_filter_guard({'and', Left, Right}, Variables) ->
    combine_guard('andalso', root_filter_guard(Left, Variables), root_filter_guard(Right, Variables));
root_filter_guard({'or', Left, Right}, Variables) ->
    combine_guard('orelse', root_filter_guard(Left, Variables), root_filter_guard(Right, Variables));
root_filter_guard({'not', Predicate}, Variables) ->
    case root_filter_guard(Predicate, Variables) of
        true -> false;
        false -> true;
        Guard -> {'not', Guard}
    end;
root_filter_guard(_Invalid, _Variables) -> false.

argument_variable(Index, Variables)
        when is_integer(Index), Index >= 0, Index < length(Variables) ->
    {ok, lists:nth(Index + 1, Variables)};
argument_variable(_Index, _Variables) -> error.

existing_tag(Tag) when is_binary(Tag), byte_size(Tag) > 0, byte_size(Tag) =< 255 ->
    try {ok, binary_to_existing_atom(Tag, utf8)}
    catch error:badarg -> error
    end;
existing_tag(Tag) when is_atom(Tag) -> {ok, Tag};
existing_tag(_Tag) -> error.

compare_guard(equal, Guard) -> Guard;
compare_guard(not_equal, Guard) -> {'not', Guard};
compare_guard(_Comparator, _Guard) -> false.

combine_guard('andalso', false, _Right) -> false;
combine_guard('andalso', _Left, false) -> false;
combine_guard('andalso', true, Right) -> Right;
combine_guard('andalso', Left, true) -> Left;
combine_guard('orelse', true, _Right) -> true;
combine_guard('orelse', _Left, true) -> true;
combine_guard('orelse', false, Right) -> Right;
combine_guard('orelse', Left, false) -> Left;
combine_guard(Operator, Left, Right) -> {Operator, Left, Right}.

type_guard(<<"atom">>, Variable) -> {ok, {is_atom, Variable}};
type_guard(<<"tuple">>, Variable) -> {ok, {is_tuple, Variable}};
type_guard(<<"list">>, Variable) -> {ok, {is_list, Variable}};
type_guard(<<"map">>, Variable) -> {ok, {is_map, Variable}};
type_guard(<<"binary">>, Variable) -> {ok, {is_binary, Variable}};
type_guard(<<"integer">>, Variable) -> {ok, {is_integer, Variable}};
type_guard(<<"float">>, Variable) -> {ok, {is_float, Variable}};
type_guard(<<"pid">>, Variable) -> {ok, {is_pid, Variable}};
type_guard(<<"reference">>, Variable) -> {ok, {is_reference, Variable}};
type_guard(<<"port">>, Variable) -> {ok, {is_port, Variable}};
type_guard(<<"function">>, Variable) -> {ok, {is_function, Variable}};
type_guard(Kind, Variable) when is_atom(Kind) ->
    type_guard(atom_to_binary(Kind, utf8), Variable);
type_guard(_Kind, _Variable) -> error.

record_root(_Pid, _Call, _Timestamp, State = #state{root_count = Count, max_roots = Max})
        when Count >= Max ->
    State;
record_root(Pid, {M, F, Args}, Timestamp, State) ->
    Event = (base_event(root, Pid, Timestamp, State))#{
        mfa => #{module => M, function => F, arity => length(Args)},
        arguments => shape_term(Args, State#state.privacy),
        evidence => exact
    },
    Next = enqueue_internal(Event, State#state{root_count = State#state.root_count + 1}),
    maybe_disarm_root(flush(Next)).

record_seq_trace({send, Serial, From, To, Message}, Timestamp, State) ->
    Event = seq_event(send, Serial, From, To, Message, Timestamp, State),
    flush(enqueue_internal(Event, State));
record_seq_trace({'receive', Serial, From, To, Message}, Timestamp, State) ->
    Event = seq_event('receive', Serial, From, To, Message, Timestamp, State),
    flush(enqueue_internal(Event, State));
record_seq_trace({print, Serial, From, To, Info}, Timestamp, State) ->
    Event = seq_event(print, Serial, From, To, Info, Timestamp, State),
    flush(enqueue_internal(Event, State));
record_seq_trace(_Unknown, _Timestamp, State) ->
    State.

record_spawn(Parent, Child, {Module, Function, Arguments}, Timestamp, State) ->
    Arity = initial_call_arity(Arguments),
    Event = (base_event(spawn, Parent, Timestamp, State))#{
        child => process_view(Child),
        initial_call => #{
            module => Module,
            function => Function,
            arity => Arity
        },
        semantic => mfa_semantic(Module, Function, Arity),
        evidence => exact
    },
    flush(enqueue_internal(Event, State));
record_spawn(_Parent, _Child, _InitialCall, _Timestamp, State) ->
    State.

record_exit(Process, Reason, Timestamp, State) ->
    Event = (base_event(exit, Process, Timestamp, State))#{
        reason => shape_term(Reason, State#state.privacy),
        semantic => term_tag(Reason),
        evidence => exact
    },
    flush(enqueue_internal(Event, State)).

record_register(Process, Name, Timestamp, State) when is_atom(Name) ->
    BaseEvent = base_event(register, Process, Timestamp, State),
    Identity = maps:get(process, BaseEvent),
    Metadata = maps:get(metadata, Identity, #{}),
    Event = BaseEvent#{
        process => Identity#{metadata => Metadata#{registered_name => Name}},
        name => Name,
        semantic => atom_to_binary(Name, utf8),
        evidence => exact
    },
    flush(enqueue_internal(Event, State));
record_register(_Process, _Name, _Timestamp, State) ->
    State.

record_link(Process, Peer, Timestamp, State) ->
    Event = (base_event(link, Process, Timestamp, State))#{
        peer => process_view(Peer),
        semantic => link,
        evidence => exact
    },
    flush(enqueue_internal(Event, State)).

initial_call_arity(Arguments) when is_list(Arguments) -> length(Arguments);
initial_call_arity(Arity) when is_integer(Arity), Arity >= 0 -> Arity;
initial_call_arity(_Arguments) -> 0.

mfa_semantic(Module, Function, Arity) when is_atom(Module), is_atom(Function) ->
    <<(atom_to_binary(Module, utf8))/binary, ":",
      (atom_to_binary(Function, utf8))/binary, "/",
      (integer_to_binary(Arity))/binary>>;
mfa_semantic(_Module, _Function, Arity) ->
    <<"unknown:unknown/", (integer_to_binary(Arity))/binary>>.

term_tag(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
term_tag(Reason) when is_tuple(Reason), tuple_size(Reason) > 0,
                            is_atom(element(1, Reason)) ->
    atom_to_binary(element(1, Reason), utf8);
term_tag(Reason) when is_tuple(Reason) -> <<"tuple">>;
term_tag(Reason) when is_list(Reason) -> <<"list">>;
term_tag(Reason) when is_map(Reason) -> <<"map">>;
term_tag(Reason) when is_binary(Reason) -> <<"binary">>;
term_tag(Reason) when is_number(Reason) -> <<"number">>;
term_tag(_Reason) -> <<"other">>.

seq_event(Kind, {Previous, Current}, From, To, Message, Timestamp, State) ->
    Actor = event_actor(Kind, From, To),
    (base_event(Kind, process_or_node(Actor), Timestamp, State))#{
        from => process_view(From),
        to => process_view(To),
        previous_serial => Previous,
        serial => Current,
        message => shape_term(Message, State#state.privacy),
        semantic => semantic(Message, State#state.preset),
        evidence => exact
    };
seq_event(Kind, Serial, From, To, Message, Timestamp, State) ->
    Actor = event_actor(Kind, From, To),
    (base_event(Kind, process_or_node(Actor), Timestamp, State))#{
        from => process_view(From),
        to => process_view(To),
        serial => shape_term(Serial, State#state.privacy),
        message => shape_term(Message, State#state.privacy),
        semantic => semantic(Message, State#state.preset),
        evidence => exact
    }.

event_actor('receive', _From, To) -> To;
event_actor(_Kind, From, _To) -> From.

base_event(Kind, Process, Timestamp, State) ->
    #{
        id => new_event_id(),
        root_id => State#state.label,
        kind => Kind,
        node => atom_to_binary(node(), utf8),
        process => process_identity(Process),
        local_timestamp_ns => timestamp_ns(Timestamp)
    }.

maybe_disarm_root(State = #state{root_count = Count, max_roots = Max, session = Session, trigger = MFA})
        when Count >= Max, Session =/= undefined ->
    _ = safe_disable_meta(Session, MFA),
    State;
maybe_disarm_root(State) ->
    State.

enqueue_internal(Event, State = #state{completeness = complete}) ->
    case accept_event(Event, State) of
        {ok, Accepted} -> Accepted;
        {truncated, _Reason, Truncated} -> Truncated
    end;
enqueue_internal(_Event, State) ->
    State.

accept_event(Event, State) ->
    Size = erlang:external_size(Event),
    case budget_reason(Size, State) of
        none ->
            Queue = queue:in(Event, State#state.queue),
            {ok, State#state{
                queue = Queue,
                queued = State#state.queued + 1,
                event_count = State#state.event_count + 1,
                byte_count = State#state.byte_count + Size
            }};
        queue_budget when State#state.mode =:= live ->
            accept_live_overflow(Event, Size, State);
        Reason ->
            {truncated, Reason, truncate_capture(Reason, State)}
    end.

budget_reason(_Size, #state{event_count = Count, max_events = Max}) when Count >= Max ->
    event_budget;
budget_reason(Size, #state{byte_count = Bytes, max_bytes = Max}) when Bytes + Size > Max ->
    byte_budget;
budget_reason(_Size, #state{queued = Queued, max_agent_mailbox = Max}) when Queued >= Max ->
    queue_budget;
budget_reason(_Size, _State) ->
    none.

accept_live_overflow(Event, Size, State) ->
    case queue:out(State#state.queue) of
        {{value, Dropped}, Rest} ->
            DroppedSize = erlang:external_size(Dropped),
            Queue = queue:in(Event, Rest),
            {ok, State#state{
                queue = Queue,
                byte_count = State#state.byte_count - DroppedSize + Size,
                event_count = State#state.event_count + 1,
                dropped_live = State#state.dropped_live + 1,
                completeness = {gapped, State#state.dropped_live + 1}
            }};
        {empty, _} ->
            {ok, State}
    end.

truncate_capture(_Reason, State = #state{completeness = {truncated, _}}) ->
    State;
truncate_capture(Reason, State) ->
    State#state.owner ! {beamtrace_stop, State#state.capture_id, {truncated, Reason}},
    Cleaned = cleanup_capture(State),
    Cleaned#state{completeness = {truncated, Reason}}.

flush(State = #state{credits = Credits, queued = Queued}) when Credits > 0, Queued > 0 ->
    {Batch, Queue, Taken} = take_batch(
        State#state.queue,
        erlang:min(State#state.batch_size, Queued),
        []
    ),
    Sequence = State#state.batch_sequence + 1,
    GapPrefix = case State#state.dropped_live of
        0 -> [];
        Dropped -> [#{
            kind => gap,
            dropped_events => Dropped,
            reason => relay_backpressure,
            evidence => exact
        }]
    end,
    State#state.owner ! {
        beamtrace_batch,
        State#state.capture_id,
        Sequence,
        GapPrefix ++ Batch
    },
    flush(State#state{
        credits = Credits - 1,
        queue = Queue,
        queued = Queued - Taken,
        batch_sequence = Sequence,
        dropped_live = 0
    });
flush(State) ->
    State.

take_batch(Queue, 0, Acc) ->
    {lists:reverse(Acc), Queue, length(Acc)};
take_batch(Queue, Remaining, Acc) ->
    case queue:out(Queue) of
        {{value, Event}, Rest} ->
            take_batch(Rest, Remaining - 1, [Event | Acc]);
        {empty, _} ->
            {lists:reverse(Acc), Queue, length(Acc)}
    end.

status_map(State) ->
    #{
        capture_id => State#state.capture_id,
        armed => State#state.armed,
        trigger => State#state.trigger,
        completeness => State#state.completeness,
        queued => State#state.queued,
        credits => State#state.credits,
        event_count => State#state.event_count,
        byte_count => State#state.byte_count,
        root_count => State#state.root_count,
        owns_system_tracer => State#state.owns_system_tracer
    }.

cleanup_capture(State) ->
    _ = cancel_timer(State#state.ttl_timer),
    case State#state.session of
        undefined -> ok;
        Session -> _ = safe_destroy_session(Session)
    end,
    case State#state.owns_system_tracer of
        true -> _ = release_system_tracer(self());
        false -> ok
    end,
    State#state{
        session = undefined,
        trigger = undefined,
        label = undefined,
        owns_system_tracer = false,
        armed = false,
        ttl_timer = undefined
    }.

cancel_timer(undefined) -> ok;
cancel_timer(Reference) ->
    _ = erlang:cancel_timer(Reference),
    ok.

safe_disable_meta(Session, MFA) ->
    try trace:function(Session, MFA, false, [meta])
    catch
        _:_ -> false
    end.

safe_destroy_session(Session) ->
    try trace:session_destroy(Session)
    catch
        _:_ -> false
    end.

claim_system_tracer(Tracer) when is_pid(Tracer) ->
    case seq_trace:get_system_tracer() of
        false ->
            case seq_trace:set_system_tracer(Tracer) of
                false -> {ok, false};
                Existing ->
                    %% A concurrent claimant won between get and set. Restore it
                    %% immediately and refuse exact mode.
                    _ = seq_trace:set_system_tracer(Existing),
                    {error, {system_tracer_occupied, Existing}}
            end;
        Tracer ->
            {ok, Tracer};
        Existing ->
            {error, {system_tracer_occupied, Existing}}
    end.

release_system_tracer(Tracer) ->
    case seq_trace:get_system_tracer() of
        Tracer ->
            _ = seq_trace:reset_trace(),
            case seq_trace:get_system_tracer() of
                Tracer ->
                    _ = seq_trace:set_system_tracer(false),
                    ok;
                _Changed ->
                    {error, tracer_changed_during_cleanup}
            end;
        _Other ->
            {error, not_owner}
    end.

shape_term(Term, Options) when is_map(Options) ->
    shape_term(Term, Options, 0).

shape_term(_Term, #{max_depth := MaxDepth}, Depth) when Depth > MaxDepth ->
    #{kind => redacted, reason => depth_limit};
shape_term(Term, _Options, _Depth) when is_atom(Term) ->
    #{kind => atom, tag => Term};
shape_term(Term, Options, _Depth) when is_binary(Term) ->
    scalar_or_raw_binary(Term, Options);
shape_term(Term, Options, _Depth) when is_integer(Term) ->
    scalar_or_raw(integer, Term, Options);
shape_term(Term, Options, _Depth) when is_float(Term) ->
    scalar_or_raw(float, Term, Options);
shape_term(Term, Options, Depth) when is_tuple(Term) ->
    Max = maps:get(max_items, Options, 32),
    Count = erlang:min(tuple_size(Term), Max),
    Items = [shape_term(element(Index, Term), Options, Depth + 1)
        || Index <- lists:seq(1, Count)],
    #{kind => tuple, size => tuple_size(Term), items => Items};
shape_term(Term, Options, Depth) when is_list(Term) ->
    Max = maps:get(max_items, Options, 32),
    {Items, Length, TailKind} = shape_list(Term, Options, Depth + 1, Max, [], 0),
    #{kind => list, length => Length, tail => TailKind, items => Items};
shape_term(Term, Options, Depth) when is_map(Term) ->
    Max = maps:get(max_items, Options, 32),
    Iterator = maps:iterator(Term),
    Entries = shape_map(Iterator, Options, Depth + 1, Max, []),
    #{kind => map, size => map_size(Term), entries => Entries};
shape_term(Term, Options, _Depth) when is_pid(Term) ->
    scalar_or_raw(pid, Term, Options);
shape_term(Term, Options, _Depth) when is_reference(Term) ->
    scalar_or_raw(reference, Term, Options);
shape_term(Term, Options, _Depth) when is_port(Term) ->
    scalar_or_raw(port, Term, Options);
shape_term(Term, Options, _Depth) when is_function(Term) ->
    scalar_or_raw(function, Term, Options);
shape_term(Term, Options, _Depth) ->
    scalar_or_raw(other, Term, Options).

shape_list([], _Options, _Depth, _Remaining, Acc, Count) ->
    {lists:reverse(Acc), Count, proper};
shape_list(Rest, _Options, _Depth, 0, Acc, Count) ->
    {lists:reverse(Acc), Count + bounded_list_tail_length(Rest, 100000), truncated};
shape_list([Head | Tail], Options, Depth, Remaining, Acc, Count) ->
    shape_list(
        Tail,
        Options,
        Depth,
        Remaining - 1,
        [shape_term(Head, Options, Depth) | Acc],
        Count + 1
    );
shape_list(Improper, Options, Depth, _Remaining, Acc, Count) ->
    Tail = shape_term(Improper, Options, Depth),
    {lists:reverse([Tail | Acc]), Count, improper}.

bounded_list_tail_length([], _Budget) -> 0;
bounded_list_tail_length(_Rest, 0) -> 0;
bounded_list_tail_length([_ | Tail], Budget) ->
    1 + bounded_list_tail_length(Tail, Budget - 1);
bounded_list_tail_length(_Improper, _Budget) -> 0.

shape_map(_Iterator, _Options, _Depth, 0, Acc) ->
    lists:reverse(Acc);
shape_map(Iterator, Options, Depth, Remaining, Acc) ->
    case maps:next(Iterator) of
        none -> lists:reverse(Acc);
        {Key, Value, Next} ->
            ShapedKey = shape_term(Key, Options, Depth),
            ShapedValue = case is_redacted_key(Key, Options) of
                true -> #{kind => redacted, reason => key_policy};
                false -> shape_term(Value, Options, Depth)
            end,
            shape_map(
                Next,
                Options,
                Depth,
                Remaining - 1,
                [#{key => ShapedKey, value => ShapedValue} | Acc]
            )
    end.

scalar_or_raw_binary(Binary, Options) ->
    Fingerprint = fingerprint(Binary, Options),
    case maps:get(mode, Options, metadata) of
        raw ->
            Limit = maps:get(max_binary_bytes, Options, 256),
            ShownBytes = erlang:min(byte_size(Binary), Limit),
            #{
                kind => binary,
                bytes => byte_size(Binary),
                value => binary:part(Binary, 0, ShownBytes),
                truncated => byte_size(Binary) > Limit,
                fingerprint => Fingerprint
            };
        _ ->
            #{kind => binary, bytes => byte_size(Binary), fingerprint => Fingerprint}
    end.

scalar_or_raw(Type, Term, Options) ->
    Fingerprint = fingerprint(Term, Options),
    case maps:get(mode, Options, metadata) of
        raw -> #{kind => scalar, type => Type, value => printable(Term), fingerprint => Fingerprint};
        _ -> #{kind => scalar, type => Type, fingerprint => Fingerprint}
    end.

fingerprint(Term, Options) ->
    Salt = maps:get(salt, Options, <<>>),
    Digest = crypto:hash(sha256, [Salt, <<0>>, term_to_binary(Term)]),
    hex(Digest).

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>> || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.

printable(Pid) when is_pid(Pid) -> list_to_binary(pid_to_list(Pid));
printable(Reference) when is_reference(Reference) ->
    list_to_binary(erlang:ref_to_list(Reference));
printable(Port) when is_port(Port) -> list_to_binary(erlang:port_to_list(Port));
printable(Function) when is_function(Function) ->
    list_to_binary(io_lib:format("~p", [erlang:fun_info(Function, module)]));
printable(Term) -> Term.

is_redacted_key(Key, Options) ->
    Normalized = normalize_key(Key),
    Keys = maps:get(redact_keys, Options, default_redact_keys()),
    lists:member(Normalized, [normalize_key(Item) || Item <- Keys]).

normalize_key(Key) when is_atom(Key) ->
    string:lowercase(atom_to_list(Key));
normalize_key(Key) when is_binary(Key) ->
    string:lowercase(binary_to_list(Key));
normalize_key(Key) when is_list(Key) ->
    string:lowercase(Key);
normalize_key(_Key) ->
    "".

default_redact_keys() ->
    [password, passwd, authorization, cookie, secret, token, api_key, apikey].

process_identity(Pid) when is_pid(Pid) ->
    Metadata = bounded_process_metadata(Pid),
    #{physical => process_view(Pid), metadata => Metadata};
process_identity(Node) when is_atom(Node) ->
    #{physical => process_view(Node), metadata => #{}};
process_identity(Other) ->
    #{physical => process_view(Other), metadata => #{}}.

bounded_process_metadata(Pid) ->
    case process_info(Pid, [registered_name, initial_call, dictionary]) of
        undefined -> #{};
        Info ->
            Registered = case proplists:get_value(registered_name, Info, []) of
                [] -> undefined;
                Name -> Name
            end,
            InitialCall = proplists:get_value(initial_call, Info, undefined),
            Dictionary = proplists:get_value(dictionary, Info, []),
            #{
                registered_name => Registered,
                initial_call => InitialCall,
                ancestors => proplists:get_value('$ancestors', Dictionary, []),
                process_label => proplists:get_value('$process_label', Dictionary, undefined)
            }
    end.

process_view(Pid) when is_pid(Pid) ->
    #{
        node => atom_to_binary(node(Pid), utf8),
        pid => list_to_binary(pid_to_list(Pid))
    };
process_view({Name, Node}) when is_atom(Name), is_atom(Node) ->
    #{node => atom_to_binary(Node, utf8), registered_name => Name};
process_view(Node) when is_atom(Node) ->
    #{node => atom_to_binary(Node, utf8)};
process_view(Port) when is_port(Port) ->
    #{node => atom_to_binary(node(Port), utf8), port => list_to_binary(port_to_list(Port))};
process_view(Other) ->
    #{kind => external, fingerprint => hex(crypto:hash(sha256, term_to_binary(Other)))}.

process_or_node(Pid) when is_pid(Pid) -> Pid;
process_or_node(Node) when is_atom(Node) -> Node;
process_or_node(_Other) -> node().

classify_message({'$gen_call', _From, _Request}) -> call;
classify_message({'$gen_cast', _Request}) -> cast;
classify_message({'DOWN', _Reference, process, _Pid, _Reason}) -> down;
classify_message({'EXIT', _Pid, _Reason}) -> exit_signal;
classify_message({Reference, _Reply}) when is_reference(Reference) -> reply;
classify_message(timeout) -> timeout;
classify_message(Message) when is_tuple(Message), tuple_size(Message) > 0 ->
    case element(1, Message) of
        spawn_request -> spawn_protocol;
        spawn_reply -> spawn_protocol;
        _ -> message
    end;
classify_message(_Message) -> message.

semantic({'$gen_call', _From, _Request}, gen_server) -> gen_server_call;
semantic({'$gen_cast', _Request}, gen_server) -> gen_server_cast;
semantic({Reference, _Reply}, gen_server) when is_reference(Reference) ->
    gen_server_reply;
semantic({call, _From, _Request}, gleam_actor) -> gleam_actor_call;
semantic({cast, _Request}, gleam_actor) -> gleam_actor_cast;
semantic({reply, _Reference, _Reply}, gleam_actor) -> gleam_actor_reply;
semantic({request, _Method, _Target}, wisp_mist) -> http_request;
semantic({response, _Status, _Body}, wisp_mist) -> http_response;
semantic(#{'__struct__' := 'Elixir.Phoenix.Socket.Message'}, phoenix) ->
    phoenix_socket_message;
semantic(#{'__struct__' := 'Elixir.Phoenix.Socket.Broadcast'}, phoenix) ->
    phoenix_broadcast;
semantic({'EXIT', _Pid, _Reason}, erlang_supervisor) -> supervisor_exit;
semantic({'DOWN', _Reference, process, _Pid, _Reason}, erlang_supervisor) ->
    supervisor_down;
semantic(Message, _Preset) -> classify_message(Message).

timestamp_ns(Value) when is_integer(Value) -> Value;
timestamp_ns({Monotonic, _Unique}) when is_integer(Monotonic) -> Monotonic;
timestamp_ns({MegaSeconds, Seconds, MicroSeconds}) ->
    ((MegaSeconds * 1000000 + Seconds) * 1000000000) + MicroSeconds * 1000;
timestamp_ns(_Other) -> erlang:monotonic_time(nanosecond).

new_capture_id() ->
    <<"capture-", (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.

new_event_id() ->
    <<"event-", (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.

validate_mfa({Module, Function, Arity})
        when is_atom(Module), is_atom(Function), is_integer(Arity), Arity >= 0 ->
    ok;
validate_mfa(_MFA) ->
    {error, invalid_mfa}.

positive_option(Key, Options, Default) ->
    case maps:get(Key, Options, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.

otp_supported() ->
    try
        Release = erlang:system_info(otp_release),
        Major = case Release of
            Binary when is_binary(Binary) -> binary_to_integer(Binary);
            String when is_list(String) -> list_to_integer(String)
        end,
        Major >= 27
    catch
        _:_ -> false
    end.
