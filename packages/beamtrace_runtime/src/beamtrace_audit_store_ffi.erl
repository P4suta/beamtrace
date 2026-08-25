%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_audit_store_ffi).

-export([
    new/0,
    new_with_persistence/2,
    append/6,
    append_transactional/7,
    snapshot/1,
    close/1
]).

-define(TIMEOUT, 5000).

new() ->
    start_store('beamtrace_runtime@audit':new(), fun(_Log) -> {ok, nil} end).

new_with_persistence(InitialLog, Persist)
        when is_function(Persist, 1) ->
    start_store(InitialLog, Persist).

start_store(InitialLog, Persist) ->
    Owner = self(),
    spawn(fun() ->
        OwnerMonitor = erlang:monitor(process, Owner),
        loop(InitialLog, Persist, OwnerMonitor)
    end).

append(Store, TimestampMs, Actor, Action, Resource, Outcome)
        when is_pid(Store), is_integer(TimestampMs), is_binary(Actor),
             is_binary(Action), is_binary(Resource), is_binary(Outcome) ->
    Ref = make_ref(),
    Store ! {append, self(), Ref, TimestampMs, Actor, Action, Resource, Outcome},
    receive
        {Ref, ok} -> nil;
        {Ref, {error, Reason}} -> error({audit_store_persist_failed, Reason})
    after ?TIMEOUT -> error(audit_store_timeout)
    end.

append_transactional(
        Store, TimestampMs, Actor, Action, Resource, Outcome, Persist
    )
        when is_pid(Store), is_integer(TimestampMs), is_binary(Actor),
             is_binary(Action), is_binary(Resource), is_binary(Outcome),
             is_function(Persist, 1) ->
    Ref = make_ref(),
    Store ! {
        append_transactional,
        self(),
        Ref,
        TimestampMs,
        Actor,
        Action,
        Resource,
        Outcome,
        Persist
    },
    receive
        {Ref, {ok, Value}} -> {ok, Value};
        {Ref, {error, Reason}} -> {error, reason_binary(Reason)}
    after ?TIMEOUT -> {error, <<"audit_store_timeout">>}
    end.

snapshot(Store) when is_pid(Store) ->
    Ref = make_ref(),
    Store ! {snapshot, self(), Ref},
    receive
        {Ref, Log} -> Log
    after ?TIMEOUT -> error(audit_store_timeout)
    end.

close(Store) when is_pid(Store) ->
    Ref = make_ref(),
    Store ! {close, self(), Ref},
    receive
        {Ref, ok} -> nil
    after ?TIMEOUT -> nil
    end.

loop(Log, Persist, OwnerMonitor) ->
    receive
        {append, From, Ref, TimestampMs, Actor, Action, Resource, Outcome} ->
            Next = 'beamtrace_runtime@audit':append(
                Log,
                TimestampMs,
                Actor,
                Action,
                Resource,
                Outcome
            ),
            case persist(Persist, Next) of
                ok ->
                    From ! {Ref, ok},
                    loop(Next, Persist, OwnerMonitor);
                {error, Reason} ->
                    From ! {Ref, {error, Reason}},
                    loop(Log, Persist, OwnerMonitor)
            end;
        {append_transactional, From, Ref, TimestampMs, Actor, Action,
         Resource, Outcome, Transaction} ->
            Next = 'beamtrace_runtime@audit':append(
                Log,
                TimestampMs,
                Actor,
                Action,
                Resource,
                Outcome
            ),
            case persist_value(Transaction, Next) of
                {ok, Value} ->
                    From ! {Ref, {ok, Value}},
                    loop(Next, Persist, OwnerMonitor);
                {error, Reason} ->
                    From ! {Ref, {error, Reason}},
                    loop(Log, Persist, OwnerMonitor)
            end;
        {snapshot, From, Ref} ->
            From ! {Ref, Log},
            loop(Log, Persist, OwnerMonitor);
        {close, From, Ref} ->
            From ! {Ref, ok},
            ok;
        {'DOWN', OwnerMonitor, process, _Owner, _Reason} ->
            ok;
        _Unexpected ->
            loop(Log, Persist, OwnerMonitor)
    end.

persist(Persist, Log) ->
    try Persist(Log) of
        {ok, nil} -> ok;
        {error, Reason} -> {error, Reason};
        Other -> {error, {invalid_persistence_result, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

persist_value(Persist, Log) ->
    try Persist(Log) of
        {ok, Value} -> {ok, Value};
        {error, Reason} -> {error, Reason};
        Other -> {error, {invalid_persistence_result, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
