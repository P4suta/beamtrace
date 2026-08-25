%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_capture_session_ffi).
-behaviour(gen_server).

-export([start/4, arm/2, status/1, await_result/2, result/1, nodes/1,
    search_mfas/4, live_snapshot/5, cancel/1, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    backend,
    search_backend,
    live_backend,
    nodes = [],
    phase = idle,
    worker = undefined,
    monitor = undefined,
    run_ref = undefined,
    result = undefined,
    error = undefined,
    waiters = [],
    close_waiter = undefined,
    live_node = undefined,
    live_limit = 0,
    live_offset = 0,
    live_generation = 0,
    live_sampled_at_ms = 0,
    live_samples = [],
    live_previous = []
}).

start(Nodes, Backend, SearchBackend, LiveBackend)
        when is_list(Nodes), is_function(Backend, 1), is_function(SearchBackend, 3),
             is_function(LiveBackend, 3) ->
    {ok, Pid} = gen_server:start(
        ?MODULE, {Nodes, Backend, SearchBackend, LiveBackend}, []
    ),
    Pid.

arm(Store, Spec) ->
    safe_call(Store, {arm, Spec}, 10000).

status(Store) ->
    case safe_call(Store, status, 10000) of
        {error, <<"session_closed">>} -> {failed, <<"session_closed">>};
        Value -> Value
    end.

await_result(Store, TimeoutMs) when is_integer(TimeoutMs), TimeoutMs > 0 ->
    safe_call(Store, await_result, TimeoutMs).

result(Store) ->
    safe_call(Store, result, 10000).

nodes(Store) ->
    case safe_call(Store, nodes, 10000) of
        {error, _} -> [];
        Values -> Values
    end.

search_mfas(Store, Node, Query, Limit) ->
    safe_call(Store, {search_mfas, Node, Query, Limit}, 15000).

live_snapshot(Store, Node, Limit, NowMs, TtlMs) ->
    safe_call(Store, {live_snapshot, Node, Limit, NowMs, TtlMs}, 15000).

cancel(Store) ->
    safe_call(Store, cancel, 10000).

close(Store) ->
    _ = safe_call(Store, close, 15000),
    nil.

init({Nodes, Backend, SearchBackend, LiveBackend}) ->
    {ok, #state{
        backend = Backend,
        search_backend = SearchBackend,
        live_backend = LiveBackend,
        nodes = Nodes
    }}.

handle_call({arm, _Spec}, _From, State = #state{phase = Phase})
        when Phase =:= armed; Phase =:= cancelling ->
    {reply, {error, <<"capture_already_running">>}, State};
handle_call({arm, Spec}, _From, State = #state{backend = Backend}) ->
    Parent = self(),
    RunRef = make_ref(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        Outcome = safe_backend(Backend, Spec),
        Parent ! {capture_result, RunRef, Outcome}
    end),
    {reply, {ok, nil}, State#state{
        phase = armed,
        worker = Worker,
        monitor = Monitor,
        run_ref = RunRef,
        result = undefined,
        error = undefined,
        waiters = []
    }};
handle_call(status, _From, State) ->
    {reply, status_value(State), State};
handle_call(await_result, _From, State = #state{phase = idle}) ->
    {reply, {error, <<"capture_not_ready">>}, State};
handle_call(await_result, _From, State = #state{phase = ready, result = Result}) ->
    {reply, {ok, Result}, State};
handle_call(await_result, _From, State = #state{phase = failed, error = Reason}) ->
    {reply, {error, Reason}, State};
handle_call(await_result, From, State = #state{waiters = Waiters}) ->
    {noreply, State#state{waiters = [From | Waiters]}};
handle_call(result, _From, State = #state{phase = ready, result = Result}) ->
    {reply, {ok, Result}, State};
handle_call(result, _From, State = #state{phase = failed, error = Reason}) ->
    {reply, {error, Reason}, State};
handle_call(result, _From, State) ->
    {reply, {error, <<"capture_not_ready">>}, State};
handle_call(nodes, _From, State = #state{nodes = Nodes}) ->
    {reply, Nodes, State};
handle_call(
    {search_mfas, Node, Query, Limit},
    _From,
    State = #state{search_backend = SearchBackend}
) ->
    {reply, safe_search(SearchBackend, Node, Query, Limit), State};
handle_call(
    {live_snapshot, Node, Limit, NowMs, TtlMs},
    _From,
    State = #state{live_node = Node, live_limit = CachedLimit,
        live_generation = Generation, live_sampled_at_ms = SampledAt}
) when Generation > 0, CachedLimit >= Limit, NowMs >= SampledAt,
       NowMs - SampledAt < TtlMs ->
    {reply, {ok, live_snapshot_value(State, Limit)}, State};
handle_call(
    {live_snapshot, Node, Limit, NowMs, _TtlMs},
    _From,
    State = #state{live_backend = LiveBackend, live_node = CachedNode,
        live_offset = Offset, live_samples = Current,
        live_generation = Generation}
) ->
    EffectiveOffset = case CachedNode =:= Node of true -> Offset; false -> 0 end,
    case safe_live(LiveBackend, Node, EffectiveOffset, Limit) of
        {ok, {Samples, NextOffset}} ->
            Previous = case CachedNode =:= Node of true -> Current; false -> [] end,
            Next = State#state{
                live_node = Node,
                live_limit = Limit,
                live_offset = NextOffset,
                live_generation = Generation + 1,
                live_sampled_at_ms = NowMs,
                live_samples = Samples,
                live_previous = Previous
            },
            {reply, {ok, live_snapshot_value(Next, Limit)}, Next};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call(cancel, _From, State = #state{phase = Phase, worker = Worker})
        when Phase =:= armed; Phase =:= cancelling ->
    Worker ! beamtrace_cancel,
    {reply, {ok, nil}, State#state{phase = cancelling}};
handle_call(cancel, _From, State) ->
    {reply, {ok, nil}, State};
handle_call(close, From, State = #state{phase = Phase, worker = Worker})
        when Phase =:= armed; Phase =:= cancelling ->
    Worker ! beamtrace_cancel,
    {noreply, State#state{phase = cancelling, close_waiter = From}};
handle_call(close, _From, State) ->
    {stop, normal, {ok, nil}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, <<"unsupported_session_request">>}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(
    {capture_result, RunRef, Outcome},
    State = #state{run_ref = RunRef, monitor = Monitor}
) ->
    erlang:demonitor(Monitor, [flush]),
    finish(Outcome, State#state{worker = undefined, monitor = undefined, run_ref = undefined});
handle_info(
    {'DOWN', Monitor, process, _Worker, Reason},
    State = #state{monitor = Monitor}
) ->
    finish(
        {error, reason_binary({capture_worker_exit, Reason})},
        State#state{worker = undefined, monitor = undefined, run_ref = undefined}
    );
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{worker = Worker}) when is_pid(Worker) ->
    Worker ! beamtrace_cancel,
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

finish({ok, Result}, State) ->
    reply_waiters(State#state.waiters, {ok, Result}),
    maybe_close(State#state{
        phase = ready,
        result = Result,
        error = undefined,
        waiters = []
    });
finish({error, Reason0}, State) ->
    Reason = reason_binary(Reason0),
    reply_waiters(State#state.waiters, {error, Reason}),
    maybe_close(State#state{
        phase = failed,
        result = undefined,
        error = Reason,
        waiters = []
    }).

maybe_close(State = #state{close_waiter = undefined}) ->
    {noreply, State};
maybe_close(State = #state{close_waiter = From}) ->
    gen_server:reply(From, {ok, nil}),
    {stop, normal, State#state{close_waiter = undefined}}.

reply_waiters(Waiters, Reply) ->
    lists:foreach(fun(From) -> gen_server:reply(From, Reply) end, Waiters).

status_value(#state{phase = idle}) -> idle;
status_value(#state{phase = armed}) -> armed;
status_value(#state{phase = cancelling}) -> cancelling;
status_value(#state{phase = failed, error = Reason}) -> {failed, Reason};
status_value(#state{phase = ready,
        result = {capture_result, Events, Outcome, _Clocks}}) ->
    {ready, length(Events), outcome_status(Outcome)};
status_value(#state{phase = ready}) -> {failed, <<"invalid_capture_result">>}.

outcome_status({capture_outcome, {quiet_period, QuietMs}, [], [_ | _]}) ->
    <<"sealed_after_quiet_period:", (integer_to_binary(QuietMs))/binary,
      ":delivery_verified">>;
outcome_status({capture_outcome, {time_window, WindowMs}, [], [_ | _]}) ->
    <<"sealed_after_time_window:", (integer_to_binary(WindowMs))/binary,
      ":delivery_verified">>;
outcome_status({capture_outcome, user_stopped, [], [_ | _]}) ->
    <<"sealed_after_user_stop:delivery_verified">>;
outcome_status({capture_outcome, _End, Issues, _Receipts}) when Issues =/= [] ->
    <<"sealed:integrity_issues_present">>;
outcome_status({capture_outcome, _End, [], []}) ->
    <<"sealed:no_agent_receipts">>;
outcome_status(_) -> <<"invalid_capture_outcome">>.

safe_backend(Backend, Spec) ->
    try Backend(Spec) of
        {ok, _Result} = Ok -> Ok;
        {error, Reason} -> {error, reason_binary(Reason)};
        Other -> {error, reason_binary({invalid_backend_result, Other})}
    catch
        Class:Reason:Stacktrace ->
            {error, reason_binary({capture_backend_crash, Class, Reason, Stacktrace})}
    end.

safe_search(Backend, Node, Query, Limit) ->
    try Backend(Node, Query, Limit) of
        {ok, Candidates} when is_list(Candidates) -> {ok, Candidates};
        {error, Reason} -> {error, reason_binary(Reason)};
        Other -> {error, reason_binary({invalid_search_result, Other})}
    catch
        Class:Reason -> {error, reason_binary({mfa_search_crash, Class, Reason})}
    end.

safe_live(Backend, Node, Offset, Limit) ->
    try Backend(Node, Offset, Limit) of
        {ok, {Samples, NextOffset}}
                when is_list(Samples), is_integer(NextOffset), NextOffset >= 0 ->
            {ok, {Samples, NextOffset}};
        {error, Reason} -> {error, reason_binary(Reason)};
        Other -> {error, reason_binary({invalid_live_result, Other})}
    catch
        Class:Reason -> {error, reason_binary({live_sampling_crash, Class, Reason})}
    end.

live_snapshot_value(#state{live_generation = Generation,
        live_sampled_at_ms = SampledAt, live_samples = Samples,
        live_previous = Previous, live_offset = NextOffset}, Limit) ->
    {live_snapshot,
        Generation,
        SampledAt,
        lists:sublist(Samples, Limit),
        lists:sublist(Previous, Limit),
        NextOffset}.

safe_call(Store, Request, Timeout) when is_pid(Store) ->
    try gen_server:call(Store, Request, Timeout)
    catch
        exit:{timeout, _} -> {error, <<"timeout">>};
        exit:{noproc, _} -> {error, <<"session_closed">>};
        exit:Reason -> {error, reason_binary(Reason)}
    end;
safe_call(_Store, _Request, _Timeout) ->
    {error, <<"session_closed">>}.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
