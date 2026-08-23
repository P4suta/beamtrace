%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_team_auth_ffi).

-export([new/0, issue/7, authorize_at/3, close/1]).

new() ->
    ets:new(beamtrace_team_auth, [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]).

issue(Store, Subject, Roles, Project, Environment, NowMs, TtlMs)
        when is_reference(Store), is_binary(Subject), is_list(Roles),
             is_binary(Project), is_binary(Environment), is_integer(NowMs),
             is_integer(TtlMs), TtlMs > 0 ->
    Id = random_token(32),
    Csrf = random_token(24),
    Session = {session, Id, Csrf, Subject, Roles, Project, Environment},
    true = ets:insert(Store, {{session, hash(Id)}, NowMs + TtlMs, Session}),
    Session.

authorize_at(Store, Id, NowMs)
        when is_reference(Store), is_binary(Id), is_integer(NowMs) ->
    try ets:lookup(Store, {session, hash(Id)}) of
        [{{session, _Hash}, ExpiresAt, Session}] when NowMs =< ExpiresAt ->
            {ok, Session};
        [{{session, _Hash}, _ExpiresAt, _Session}] ->
            {error, <<"expired">>};
        [] ->
            {error, <<"invalid_session">>}
    catch
        error:badarg -> {error, <<"closed">>}
    end.

close(Store) when is_reference(Store) ->
    try ets:delete(Store), nil
    catch error:badarg -> nil
    end.

hash(Value) -> crypto:hash(sha256, Value).

random_token(Bytes) ->
    base64:encode(crypto:strong_rand_bytes(Bytes), #{mode => urlsafe, padding => false}).
