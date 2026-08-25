%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_local_auth_ffi).

-export([new_at/2, exchange/3, authorize/2, authorize_at/3, close/1, now_ms/0]).

new_at(NowMs, TtlMs) when is_integer(NowMs), is_integer(TtlMs), TtlMs > 0 ->
    Store = ets:new(beamtrace_local_auth, [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    Token = random_token(32),
    Hash = hash(Token),
    true = ets:insert(Store, {bootstrap, Hash, NowMs + TtlMs, false}),
    {Store, Token}.

exchange(Store, Token, NowMs)
        when is_reference(Store), is_binary(Token), is_integer(NowMs) ->
    case safe_lookup(Store, bootstrap) of
        [{bootstrap, Expected, ExpiresAt, Used}] ->
            Presented = hash(Token),
            case secure_equal(Presented, Expected) of
                false -> {error, <<"invalid_token">>};
                true when NowMs > ExpiresAt -> {error, <<"expired">>};
                true when Used =:= true -> {error, <<"already_used">>};
                true -> atomic_exchange(Store, Expected, ExpiresAt, NowMs)
            end;
        _ -> {error, <<"closed">>}
    end.

atomic_exchange(Store, Expected, ExpiresAt, NowMs) ->
    Match = [
        {{bootstrap, Expected, ExpiresAt, false}, [], [
            {{bootstrap, Expected, ExpiresAt, true}}
        ]}
    ],
    try ets:select_replace(Store, Match) of
        1 ->
            Session = random_token(32),
            Csrf = random_token(24),
            SessionExpires = NowMs + 8 * 60 * 60 * 1000,
            true = ets:insert(Store, {{session, hash(Session)}, SessionExpires}),
            {ok, {session, Session, Csrf}};
        0 -> {error, <<"already_used">>}
    catch
        error:badarg -> {error, <<"closed">>}
    end.

authorize(Store, Session) when is_reference(Store), is_binary(Session) ->
    authorize_at(Store, Session, now_ms()).

authorize_at(Store, Session, NowMs)
        when is_reference(Store), is_binary(Session), is_integer(NowMs) ->
    case safe_lookup(Store, {session, hash(Session)}) of
        [{{session, _Hash}, ExpiresAt}] -> NowMs =< ExpiresAt;
        _ -> false
    end.

close(Store) when is_reference(Store) ->
    try ets:delete(Store), nil
    catch error:badarg -> nil
    end.

now_ms() -> erlang:system_time(millisecond).

safe_lookup(Store, Key) ->
    try ets:lookup(Store, Key)
    catch error:badarg -> []
    end.

secure_equal(Left, Right) when byte_size(Left) =:= byte_size(Right) ->
    'beamtrace_runtime@crypto':constant_time_equal(Left, Right);
secure_equal(_Left, _Right) -> false.

hash(Value) -> 'beamtrace_runtime@crypto':sha256(Value).

random_token(Bytes) -> 'beamtrace_runtime@crypto':random_hex(Bytes).
