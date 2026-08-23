%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_relay_payload_ffi).

-export([decode_batch_parts/1]).

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

decode_batch(Batch) ->
    Allowed = [<<"type">>, <<"mode">>, <<"privacy">>, <<"items">>],
    HasUnknown = lists:any(
        fun(Key) -> not lists:member(Key, Allowed) end,
        maps:keys(Batch)
    ),
    Type = maps:get(<<"type">>, Batch, undefined),
    Mode = maps:get(<<"mode">>, Batch, undefined),
    Privacy = maps:get(<<"privacy">>, Batch, <<"metadata">>),
    Items = maps:get(<<"items">>, Batch, undefined),
    case {
        HasUnknown,
        Type,
        valid_mode(Mode),
        valid_privacy(Privacy),
        is_list(Items)
    } of
        {false, <<"batch">>, true, true, true} -> decode_items(Mode, Privacy, Items);
        _ -> {error, <<"invalid_payload">>}
    end.

decode_items(_Mode, _Privacy, Items) when length(Items) > ?MAX_EVENTS ->
    {error, <<"batch_event_limit">>};
decode_items(Mode, Privacy, Items) ->
    case lists:all(fun is_map/1, Items) of
        true ->
            Encoded = [iolist_to_binary(json:encode(Item)) || Item <- Items],
            {ok, {Mode, Privacy, Encoded}};
        false -> {error, <<"invalid_payload">>}
    end.

valid_mode(<<"exact">>) -> true;
valid_mode(<<"live">>) -> true;
valid_mode(_) -> false.

valid_privacy(<<"metadata">>) -> true;
valid_privacy(<<"raw">>) -> true;
valid_privacy(_) -> false.
