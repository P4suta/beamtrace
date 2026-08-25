%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_oidc_flow_ffi).

-export([new/0, remember/5, consume/3, close/1]).

new() ->
    ets:new(beamtrace_oidc_flow, [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]).

remember(Store, State, Attempt, Verifier, ExpiresAtMs)
        when is_reference(Store), is_binary(State), is_binary(Verifier),
             is_integer(ExpiresAtMs) ->
    Key = {attempt, hash(State)},
    try ets:insert_new(Store, {Key, ExpiresAtMs, active, Attempt, Verifier}) of
        true -> {ok, nil};
        false -> {error, <<"duplicate_state">>}
    catch
        error:badarg -> {error, <<"closed">>}
    end.

consume(Store, State, NowMs)
        when is_reference(Store), is_binary(State), is_integer(NowMs) ->
    Key = {attempt, hash(State)},
    try ets:take(Store, Key) of
        [{Key, ExpiresAtMs, active, Attempt, Verifier}] when NowMs =< ExpiresAtMs ->
            true = ets:insert(Store, {Key, ExpiresAtMs, used, Attempt, Verifier}),
            {ok, {pending, Attempt, Verifier}};
        [{Key, ExpiresAtMs, active, Attempt, Verifier}] ->
            true = ets:insert(Store, {Key, ExpiresAtMs, expired, Attempt, Verifier}),
            {error, <<"expired">>};
        [{Key, ExpiresAtMs, used, Attempt, Verifier}] ->
            true = ets:insert(Store, {Key, ExpiresAtMs, used, Attempt, Verifier}),
            {error, <<"already_used">>};
        [{Key, ExpiresAtMs, expired, Attempt, Verifier}] ->
            true = ets:insert(Store, {Key, ExpiresAtMs, expired, Attempt, Verifier}),
            {error, <<"expired">>};
        [] ->
            {error, <<"invalid_state">>}
    catch
        error:badarg -> {error, <<"closed">>}
    end.

close(Store) when is_reference(Store) ->
    try ets:delete(Store), nil
    catch error:badarg -> nil
    end.

hash(Value) -> 'beamtrace_runtime@crypto':sha256(Value).
