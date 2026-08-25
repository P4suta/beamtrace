%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_relay_payload_ffi).

-export([decode_batch_parts/1, raw_privacy/1]).

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

raw_privacy(Source) when is_binary(Source) ->
    try json:decode(Source) of
        Batch when is_map(Batch) -> maps:get(<<"privacy">>, Batch, undefined) =:= <<"raw">>;
        _ -> false
    catch
        _:_ -> false
    end;
raw_privacy(_) -> false.

decode_batch(Batch) ->
    Type = maps:get(<<"type">>, Batch, undefined),
    Mode = maps:get(<<"mode">>, Batch, undefined),
    Privacy = maps:get(<<"privacy">>, Batch, <<"metadata">>),
    Items = maps:get(<<"items">>, Batch, undefined),
    case {Type, valid_mode(Mode), Privacy, is_list(Items)} of
        {<<"batch">>, true, <<"metadata">>, true} ->
            decode_metadata(Batch, Mode, Items);
        {<<"batch">>, true, <<"raw">>, true} ->
            decode_raw(Batch, Mode, Items);
        _ -> {error, <<"invalid_payload">>}
    end.

decode_metadata(Batch, Mode, Items) ->
    Allowed = [<<"type">>, <<"mode">>, <<"privacy">>, <<"items">>],
    LegacyAllowed = [<<"type">>, <<"mode">>, <<"items">>],
    case exact_keys(Batch, Allowed) orelse exact_keys(Batch, LegacyAllowed) of
        true -> decode_items(Mode, <<"metadata">>, <<>>, [], 0, 0, Items);
        false -> {error, <<"invalid_payload">>}
    end.

decode_raw(Batch, Mode, Items) ->
    Allowed = [
        <<"type">>,
        <<"mode">>,
        <<"privacy">>,
        <<"grant">>,
        <<"policy">>,
        <<"items">>
    ],
    StoredAllowed = [
        <<"type">>,
        <<"mode">>,
        <<"privacy">>,
        <<"policy">>,
        <<"items">>
    ],
    Grant = maps:get(<<"grant">>, Batch, undefined),
    Policy = maps:get(<<"policy">>, Batch, undefined),
    Shape = case {exact_keys(Batch, Allowed), exact_keys(Batch, StoredAllowed)} of
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
    case lists:all(fun is_map/1, Items) of
        true ->
            Encoded = [iolist_to_binary(json:encode(Item)) || Item <- Items],
            {ok, {Mode, Privacy, Grant, Keys, Depth, Binary, Encoded}};
        false -> {error, <<"invalid_payload">>}
    end.

exact_keys(Map, Allowed) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Allowed).

valid_mode(<<"exact">>) -> true;
valid_mode(<<"live">>) -> true;
valid_mode(_) -> false.
