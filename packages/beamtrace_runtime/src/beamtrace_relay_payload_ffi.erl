%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_relay_payload_ffi).

-export([decode_batch_parts/1, decode_public_batch_parts/1]).

-define(MAX_EVENTS, 128).

decode_batch_parts(Source) when is_binary(Source) ->
    try json:decode(Source) of
        Batch when is_map(Batch) -> decode_batch(Batch);
        _ -> {error, <<"invalid_payload">>}
    catch
        _:_ -> {error, <<"invalid_payload">>}
    end;
decode_batch_parts(_Source) ->
    {error, <<"invalid_payload">>}.

decode_public_batch_parts(Source) when is_binary(Source) ->
    try json:decode(Source) of
        Batch when is_map(Batch) ->
            case maps:get(<<"privacy">>, Batch, undefined) of
                <<"raw">> -> {error, <<"raw_capture_not_authorized">>};
                _ -> decode_batch(Batch)
            end;
        _ -> {error, <<"invalid_payload">>}
    catch
        _:_ -> {error, <<"invalid_payload">>}
    end;
decode_public_batch_parts(_Source) ->
    {error, <<"invalid_payload">>}.

decode_batch(Batch) ->
    Type = maps:get(<<"type">>, Batch, undefined),
    Mode = maps:get(<<"mode">>, Batch, undefined),
    Privacy = maps:get(<<"privacy">>, Batch, <<"metadata">>),
    Items = maps:get(<<"items">>, Batch, undefined),
    EventSchema = maps:get(<<"event_schema">>, Batch, legacy),
    case {Type, valid_mode(Mode), Privacy, is_list(Items), valid_schema(EventSchema)} of
        {<<"batch">>, true, <<"metadata">>, true, true} ->
            decode_metadata(Batch, Mode, Items);
        {<<"batch">>, true, <<"raw">>, true, true} ->
            decode_raw(Batch, Mode, Items);
        _ -> {error, <<"invalid_payload">>}
    end.

decode_metadata(Batch, Mode, Items) ->
    Allowed = [<<"type">>, <<"event_schema">>, <<"mode">>, <<"privacy">>, <<"items">>],
    V2Allowed = [<<"type">>, <<"mode">>, <<"privacy">>, <<"items">>],
    LegacyAllowed = [<<"type">>, <<"mode">>, <<"items">>],
    case exact_keys(Batch, Allowed)
         orelse exact_keys(Batch, V2Allowed)
         orelse exact_keys(Batch, LegacyAllowed) of
        true -> decode_items(Mode, <<"metadata">>, <<>>, [], 0, 0, Items);
        false -> {error, <<"invalid_payload">>}
    end.

decode_raw(Batch, Mode, Items) ->
    Allowed = [
        <<"type">>,
        <<"event_schema">>,
        <<"mode">>,
        <<"privacy">>,
        <<"grant">>,
        <<"policy">>,
        <<"items">>
    ],
    StoredAllowed = [
        <<"type">>,
        <<"event_schema">>,
        <<"mode">>,
        <<"privacy">>,
        <<"policy">>,
        <<"items">>
    ],
    Grant = maps:get(<<"grant">>, Batch, undefined),
    Policy = maps:get(<<"policy">>, Batch, undefined),
    V2Allowed = lists:delete(<<"event_schema">>, Allowed),
    V2StoredAllowed = lists:delete(<<"event_schema">>, StoredAllowed),
    Shape = case {
        exact_keys(Batch, Allowed) orelse exact_keys(Batch, V2Allowed),
        exact_keys(Batch, StoredAllowed) orelse exact_keys(Batch, V2StoredAllowed)
    } of
        {true, _} when is_binary(Grant) -> {ok, Grant};
        {_, true} -> {ok, <<>>};
        _ -> error
    end,
    case {Shape, decode_policy(Policy)} of
        {{ok, DecodedGrant}, {ok, RedactKeys, MaxDepth, MaxBinaryBytes}} ->
            decode_items(
                Mode,
                <<"raw">>,
                DecodedGrant,
                RedactKeys,
                MaxDepth,
                MaxBinaryBytes,
                Items
            );
        _ -> {error, <<"invalid_payload">>}
    end.

decode_policy(Policy) when is_map(Policy) ->
    Allowed = [<<"redact_keys">>, <<"max_depth">>, <<"max_binary_bytes">>],
    RedactKeys = maps:get(<<"redact_keys">>, Policy, undefined),
    MaxDepth = maps:get(<<"max_depth">>, Policy, undefined),
    MaxBinaryBytes = maps:get(<<"max_binary_bytes">>, Policy, undefined),
    case {
        exact_keys(Policy, Allowed),
        is_list(RedactKeys),
        is_integer(MaxDepth),
        is_integer(MaxBinaryBytes)
    } of
        {true, true, true, true} ->
            case lists:all(fun is_binary/1, RedactKeys) of
                true -> {ok, RedactKeys, MaxDepth, MaxBinaryBytes};
                false -> error
            end;
        _ -> error
    end;
decode_policy(_) -> error.

decode_items(_Mode, _Privacy, _Grant, _Keys, _Depth, _Binary, Items)
        when length(Items) > ?MAX_EVENTS ->
    {error, <<"batch_event_limit">>};
decode_items(Mode, Privacy, Grant, Keys, Depth, Binary, Items) ->
    case lists:all(fun valid_event_shape/1, Items) of
        true ->
            Encoded = [iolist_to_binary(json:encode(Item)) || Item <- Items],
            {ok, {Mode, Privacy, Grant, Keys, Depth, Binary, Encoded}};
        false -> {error, <<"invalid_payload">>}
    end.

exact_keys(Map, Allowed) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Allowed).

valid_event_shape(Event) when is_map(Event) ->
    case maps:get(<<"schema_version">>, Event, undefined) of
        2 ->
            exact_keys(Event, [
                <<"schema_version">>, <<"id">>, <<"root_id">>, <<"node">>,
                <<"process">>, <<"local_instant">>, <<"event">>, <<"evidence">>
            ])
                andalso valid_process(maps:get(<<"process">>, Event, undefined))
                andalso valid_local_instant(
                    maps:get(<<"local_instant">>, Event, undefined)
                )
                andalso valid_event_kind(maps:get(<<"event">>, Event, undefined), 2)
                andalso valid_evidence(maps:get(<<"evidence">>, Event, undefined), 2);
        1 ->
            exact_keys(Event, [
                <<"schema_version">>, <<"id">>, <<"root_id">>, <<"node">>,
                <<"process">>, <<"local_timestamp_ns">>, <<"event">>, <<"evidence">>
            ])
                andalso valid_process(maps:get(<<"process">>, Event, undefined))
                andalso is_integer(maps:get(<<"local_timestamp_ns">>, Event, undefined))
                andalso valid_event_kind(maps:get(<<"event">>, Event, undefined), 1)
                andalso valid_evidence(maps:get(<<"evidence">>, Event, undefined), 1);
        _ -> false
    end;
valid_event_shape(_) -> false.

valid_process(Process) when is_map(Process) ->
    exact_keys(Process, [<<"physical">>, <<"logical">>, <<"identity_evidence">>])
        andalso valid_process_ref(maps:get(<<"physical">>, Process, undefined))
        andalso valid_logical(maps:get(<<"logical">>, Process, undefined))
        andalso valid_identity_evidence_list(
            maps:get(<<"identity_evidence">>, Process, undefined)
        );
valid_process(_) -> false.

valid_process_ref(Ref) when is_map(Ref) ->
    exact_keys(Ref, [<<"node">>, <<"pid">>]);
valid_process_ref(_) -> false.

valid_logical(null) -> true;
valid_logical(Logical) when is_map(Logical) ->
    exact_keys(Logical, [<<"id">>, <<"label">>]);
valid_logical(_) -> false.

valid_identity_evidence_list(Items) when is_list(Items) ->
    lists:all(fun valid_identity_evidence/1, Items);
valid_identity_evidence_list(_) -> false.

valid_identity_evidence(Item) when is_map(Item) ->
    case maps:get(<<"kind">>, Item, undefined) of
        <<"initial_call">> ->
            exact_keys(Item, [<<"kind">>, <<"mfa">>])
                andalso valid_mfa(maps:get(<<"mfa">>, Item, undefined));
        <<"restart_proximity">> ->
            exact_keys(Item, [<<"kind">>, <<"milliseconds">>]);
        <<"registered_name">> -> tagged_value(Item);
        <<"process_label">> -> tagged_value(Item);
        <<"ancestor">> -> tagged_value(Item);
        <<"supervisor_child_id">> -> tagged_value(Item);
        _ -> false
    end;
valid_identity_evidence(_) -> false.

valid_local_instant(Instant) when is_map(Instant) ->
    exact_keys(Instant, [<<"offset_ns">>, <<"order">>])
        andalso is_integer(maps:get(<<"offset_ns">>, Instant, undefined))
        andalso is_integer(maps:get(<<"order">>, Instant, undefined));
valid_local_instant(_) -> false.

valid_mfa(Mfa) when is_map(Mfa) ->
    exact_keys(Mfa, [<<"module">>, <<"function">>, <<"arity">>]);
valid_mfa(_) -> false.

valid_event_kind(Event, Version) when is_map(Event) ->
    case maps:get(<<"kind">>, Event, undefined) of
        <<"root">> ->
            exact_keys(Event, [<<"kind">>, <<"trigger">>, <<"arguments">>])
                andalso valid_mfa(maps:get(<<"trigger">>, Event, undefined))
                andalso valid_terms(maps:get(<<"arguments">>, Event, undefined));
        <<"send">> ->
            exact_keys(Event, [<<"kind">>, <<"to">>, <<"message">>, <<"serial">>])
                andalso valid_process_ref(maps:get(<<"to">>, Event, undefined))
                andalso valid_term(maps:get(<<"message">>, Event, undefined))
                andalso valid_serial(maps:get(<<"serial">>, Event, undefined), Version);
        <<"receive">> ->
            exact_keys(Event, [<<"kind">>, <<"from">>, <<"message">>, <<"serial">>])
                andalso valid_process_ref(maps:get(<<"from">>, Event, undefined))
                andalso valid_term(maps:get(<<"message">>, Event, undefined))
                andalso valid_serial(maps:get(<<"serial">>, Event, undefined), Version);
        <<"spawn">> ->
            exact_keys(Event, [<<"kind">>, <<"child">>, <<"initial_call">>])
                andalso valid_process_ref(maps:get(<<"child">>, Event, undefined))
                andalso valid_mfa(maps:get(<<"initial_call">>, Event, undefined));
        <<"exit">> ->
            exact_keys(Event, [<<"kind">>, <<"reason">>])
                andalso valid_term(maps:get(<<"reason">>, Event, undefined));
        <<"register">> -> tagged_value(Event);
        <<"link">> ->
            exact_keys(Event, [<<"kind">>, <<"peer">>])
                andalso valid_process_ref(maps:get(<<"peer">>, Event, undefined));
        <<"metric">> -> exact_keys(Event, [<<"kind">>, <<"name">>, <<"value">>]);
        <<"system_signal">> ->
            exact_keys(Event, [<<"kind">>, <<"name">>, <<"value">>]);
        <<"gap">> ->
            exact_keys(Event, [<<"kind">>, <<"dropped_events">>, <<"reason">>]);
        <<"stop">> -> tagged_value(Event);
        _ -> false
    end;
valid_event_kind(_, _) -> false.

valid_serial(Value, 1) -> is_integer(Value);
valid_serial(Value, 2) when is_map(Value) ->
    case maps:get(<<"kind">>, Value, undefined) of
        <<"sequence">> ->
            exact_keys(Value, [<<"kind">>, <<"previous">>, <<"current">>]);
        <<"legacy">> -> exact_keys(Value, [<<"kind">>, <<"current">>]);
        _ -> false
    end;
valid_serial(_, _) -> false.

valid_evidence(Evidence, 2) when is_map(Evidence) ->
    case maps:get(<<"kind">>, Evidence, undefined) of
        <<"exact">> -> exact_keys(Evidence, [<<"kind">>]);
        <<"inferred">> ->
            exact_keys(Evidence, [<<"kind">>, <<"inference">>])
                andalso valid_inference(maps:get(<<"inference">>, Evidence, undefined));
        _ -> false
    end;
valid_evidence(Evidence, 1) when is_map(Evidence) ->
    case maps:get(<<"kind">>, Evidence, undefined) of
        <<"exact">> -> exact_keys(Evidence, [<<"kind">>]);
        <<"inferred">> ->
            exact_keys(Evidence, [<<"kind">>, <<"reason">>, <<"confidence">>]);
        _ -> false
    end;
valid_evidence(_, _) -> false.

valid_inference(Inference) when is_map(Inference) ->
    exact_keys(Inference, [<<"method">>, <<"reason">>, <<"inputs">>])
        andalso valid_inference_inputs(maps:get(<<"inputs">>, Inference, undefined));
valid_inference(_) -> false.

valid_inference_inputs(Inputs) when is_list(Inputs) ->
    lists:all(fun valid_inference_input/1, Inputs);
valid_inference_inputs(_) -> false.

valid_inference_input(Input) when is_map(Input) ->
    case maps:get(<<"kind">>, Input, undefined) of
        <<"event">> -> exact_keys(Input, [<<"kind">>, <<"id">>]);
        <<"observation">> ->
            exact_keys(Input, [<<"kind">>, <<"name">>, <<"value">>]);
        <<"setting">> -> exact_keys(Input, [<<"kind">>, <<"name">>, <<"value">>]);
        _ -> false
    end;
valid_inference_input(_) -> false.

valid_terms(Terms) when is_list(Terms) -> lists:all(fun valid_term/1, Terms);
valid_terms(_) -> false.

valid_term(Term) when is_map(Term) ->
    case maps:get(<<"kind">>, Term, undefined) of
        <<"hidden">> -> exact_keys(Term, [<<"kind">>]);
        <<"atom">> -> tagged_value(Term);
        <<"tag">> -> tagged_value(Term);
        <<"tuple">> ->
            exact_keys(Term, [<<"kind">>, <<"items">>])
                andalso valid_terms(maps:get(<<"items">>, Term, undefined));
        <<"constructor">> ->
            exact_keys(Term, [<<"kind">>, <<"name">>, <<"fields">>])
                andalso valid_terms(maps:get(<<"fields">>, Term, undefined));
        <<"list">> ->
            exact_keys(Term, [<<"kind">>, <<"length">>, <<"items">>])
                andalso valid_terms(maps:get(<<"items">>, Term, undefined));
        <<"map">> ->
            exact_keys(Term, [<<"kind">>, <<"size">>, <<"entries">>])
                andalso valid_entries(maps:get(<<"entries">>, Term, undefined));
        <<"binary">> ->
            exact_keys(Term, [<<"kind">>, <<"bytes">>, <<"display">>, <<"fingerprint">>]);
        <<"scalar">> ->
            exact_keys(Term, [
                <<"kind">>, <<"scalar_kind">>, <<"display">>, <<"fingerprint">>
            ]);
        <<"redacted">> -> tagged_value(Term);
        _ -> false
    end;
valid_term(_) -> false.

valid_entries(Entries) when is_list(Entries) ->
    lists:all(fun valid_entry/1, Entries);
valid_entries(_) -> false.

valid_entry(Entry) when is_map(Entry) ->
    exact_keys(Entry, [<<"key">>, <<"value">>])
        andalso valid_term(maps:get(<<"key">>, Entry, undefined))
        andalso valid_term(maps:get(<<"value">>, Entry, undefined));
valid_entry(_) -> false.

tagged_value(Value) when is_map(Value) ->
    exact_keys(Value, [<<"kind">>, <<"value">>]);
tagged_value(_) -> false.

valid_mode(<<"exact">>) -> true;
valid_mode(<<"live">>) -> true;
valid_mode(_) -> false.

valid_schema(2) -> true;
valid_schema(legacy) -> true;
valid_schema(_) -> false.
