%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_relay_inbox_ffi).

-export([new/2, append/6, snapshot/2, window/4, close/1]).

-define(MAX_FRAME_BYTES, 1048576).
-define(CALL_TIMEOUT, 5000).

new(MaxFrames, MaxBytes) when is_integer(MaxFrames), is_integer(MaxBytes) ->
    Owner = self(),
    spawn_link(fun() ->
        Monitor = erlang:monitor(process, Owner),
        loop(#{
            owner => Owner,
            monitor => Monitor,
            max_frames => erlang:max(1, MaxFrames),
            max_bytes => erlang:max(1, MaxBytes),
            relays => #{}
        })
    end).

append(Store, RelayId, Sequence, Mode, Payload, ReceivedAtMs) ->
    call(Store, {append, RelayId, Sequence, Mode, Payload, ReceivedAtMs}).

snapshot(Store, RelayId) ->
    case call(Store, {snapshot, RelayId}) of
        {ok, Entries} -> Entries;
        {error, _Reason} -> []
    end.

window(Store, RelayId, Start, Limit)
        when is_binary(RelayId), byte_size(RelayId) > 0, byte_size(RelayId) =< 128,
             is_integer(Start), Start >= 0,
             is_integer(Limit), Limit > 0, Limit =< 1000 ->
    call(Store, {window, RelayId, Start, Limit});
window(_Store, _RelayId, _Start, _Limit) ->
    {error, <<"invalid_window">>}.

close(Store) when is_pid(Store) ->
    case is_process_alive(Store) of
        true ->
            _ = call(Store, close),
            nil;
        false -> nil
    end;
close(_Store) -> nil.

call(Store, Request) when is_pid(Store) ->
    Reference = make_ref(),
    Store ! {call, self(), Reference, Request},
    receive
        {Reference, Reply} -> Reply
    after ?CALL_TIMEOUT ->
        {error, <<"closed">>}
    end;
call(_Store, _Request) ->
    {error, <<"closed">>}.

loop(State = #{owner := Owner, monitor := Monitor}) ->
    receive
        {call, From, Reference, close} ->
            From ! {Reference, {ok, nil}},
            ok;
        {call, From, Reference, {snapshot, RelayId}} ->
            From ! {Reference, {ok, snapshot_relay(RelayId, State)}},
            loop(State);
        {call, From, Reference, {window, RelayId, Start, Limit}} ->
            Entries = snapshot_relay(RelayId, State),
            Total = length(Entries),
            Page = lists:sublist(drop_safe(Start, Entries), Limit),
            From ! {Reference, {ok, {window, Page, Total, Start, Limit}}},
            loop(State);
        {call, From, Reference,
                {append, RelayId, Sequence, Mode, Payload, ReceivedAtMs}} ->
            {Reply, Next} = append_frame(
                RelayId, Sequence, Mode, Payload, ReceivedAtMs, State
            ),
            From ! {Reference, Reply},
            loop(Next);
        {'DOWN', Monitor, process, Owner, _Reason} ->
            ok;
        _Other ->
            loop(State)
    end.

append_frame(RelayId, Sequence, Mode, Payload, ReceivedAtMs, State)
        when is_binary(RelayId), byte_size(RelayId) > 0, byte_size(RelayId) =< 128,
             is_integer(Sequence), Sequence > 0,
             (Mode =:= exact orelse Mode =:= live),
             is_binary(Payload), is_integer(ReceivedAtMs) ->
    MaxBytes = maps:get(max_bytes, State),
    Size = byte_size(Payload),
    case Size =< ?MAX_FRAME_BYTES andalso Size =< MaxBytes of
        false -> {{error, <<"frame_too_large">>}, State};
        true -> append_valid(
            RelayId, Sequence, Mode, Payload, Size, ReceivedAtMs, State
        )
    end;
append_frame(_RelayId, _Sequence, _Mode, _Payload, _ReceivedAtMs, State) ->
    {{error, <<"invalid_frame">>}, State}.

append_valid(RelayId, Sequence, Mode, Payload, Size, ReceivedAtMs, State) ->
    Relays = maps:get(relays, State),
    Relay = maps:get(RelayId, Relays, new_relay(Mode)),
    case maps:get(mode, Relay) =:= Mode of
        false -> {{error, <<"mode_mismatch">>}, State};
        true -> append_for_mode(
            RelayId, Sequence, Payload, Size, ReceivedAtMs, Relay, State
        )
    end.

append_for_mode(_RelayId, _Sequence, _Payload, _Size, _ReceivedAtMs,
                #{mode := exact, truncated := true}, State) ->
    {{ok, {truncated, <<"hub_inbox_budget">>}}, State};
append_for_mode(RelayId, Sequence, Payload, Size, ReceivedAtMs,
                Relay = #{mode := exact}, State) ->
    case fits(Relay, Size, State) of
        true ->
            NextRelay = enqueue(Sequence, Payload, Size, ReceivedAtMs, Relay),
            {{ok, accepted}, put_relay(RelayId, NextRelay, State)};
        false ->
            Truncated = Relay#{truncated => true},
            {{ok, {truncated, <<"hub_inbox_budget">>}},
             put_relay(RelayId, Truncated, State)}
    end;
append_for_mode(RelayId, Sequence, Payload, Size, ReceivedAtMs,
                Relay = #{mode := live}, State) ->
    Room = make_room(Relay, Size, State),
    NextRelay = enqueue(Sequence, Payload, Size, ReceivedAtMs, Room),
    {{ok, accepted}, put_relay(RelayId, NextRelay, State)}.

new_relay(Mode) ->
    #{
        mode => Mode,
        queue => queue:new(),
        count => 0,
        bytes => 0,
        dropped => 0,
        gap_at => 0,
        truncated => false
    }.

fits(Relay, Size, State) ->
    maps:get(count, Relay) < maps:get(max_frames, State)
        andalso maps:get(bytes, Relay) + Size =< maps:get(max_bytes, State).

make_room(Relay, Size, State) ->
    case fits(Relay, Size, State) of
        true -> Relay;
        false ->
            case queue:out(maps:get(queue, Relay)) of
                {{value, {payload, _Sequence, DroppedPayload, _At}}, Rest} ->
                    Reduced = Relay#{
                        queue => Rest,
                        count => maps:get(count, Relay) - 1,
                        bytes => maps:get(bytes, Relay) - byte_size(DroppedPayload),
                        dropped => maps:get(dropped, Relay) + 1
                    },
                    make_room(Reduced, Size, State);
                {empty, _Queue} -> Relay
            end
    end.

enqueue(Sequence, Payload, Size, ReceivedAtMs, Relay) ->
    Relay#{
        queue => queue:in(
            {payload, Sequence, Payload, ReceivedAtMs}, maps:get(queue, Relay)
        ),
        count => maps:get(count, Relay) + 1,
        bytes => maps:get(bytes, Relay) + Size,
        gap_at => ReceivedAtMs
    }.

put_relay(RelayId, Relay, State) ->
    Relays = maps:get(relays, State),
    State#{relays => maps:put(RelayId, Relay, Relays)}.

snapshot_relay(RelayId, State) ->
    case maps:find(RelayId, maps:get(relays, State)) of
        error -> [];
        {ok, Relay} ->
            Payloads = queue:to_list(maps:get(queue, Relay)),
            case maps:get(dropped, Relay) of
                0 -> Payloads;
                Dropped -> [
                    {gap, Dropped, <<"hub_inbox_budget">>, maps:get(gap_at, Relay)}
                    | Payloads
                ]
            end
    end.

drop_safe(0, Entries) -> Entries;
drop_safe(_Count, []) -> [];
drop_safe(Count, [_Entry | Rest]) when Count > 0 ->
    drop_safe(Count - 1, Rest).
