%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_enrollment_store_ffi).

-export([new_at/2, new_with_relays_at/4, consume/4, authenticate/6, close/1]).

new_at(NowMs, TtlMs) when is_integer(NowMs), is_integer(TtlMs) ->
    new_with_relays_at(
        NowMs,
        TtlMs,
        [],
        fun(_RelayId, _PublicKey, _EnrolledAtMs) -> {ok, nil} end
    ).

new_with_relays_at(NowMs, TtlMs, Relays, Persist)
        when is_integer(NowMs), is_integer(TtlMs), is_list(Relays),
             is_function(Persist, 3) ->
    Table = ets:new(?MODULE, [set, public, {read_concurrency, true}, {write_concurrency, true}]),
    Code = base64url(crypto:strong_rand_bytes(32)),
    Hash = crypto:hash(sha256, Code),
    ExpiresAt = NowMs + erlang:max(TtlMs, 1),
    true = ets:insert(Table, [
        {enrollment, Hash, ExpiresAt, active},
        {persistence, Persist}
    ]),
    ok = load_relays(Table, Relays),
    {Table, Code}.

consume(Table, Code, PublicKey, NowMs)
        when is_reference(Table), is_binary(Code), is_binary(PublicKey), is_integer(NowMs) ->
    case byte_size(PublicKey) of
        32 -> consume_valid_key(Table, Code, PublicKey, NowMs);
        _ -> {error, <<"invalid_public_key">>}
    end;
consume(_Table, _Code, _PublicKey, _NowMs) ->
    {error, <<"invalid_enrollment_request">>}.

authenticate(Table, RelayId, TimestampMs, Nonce, Signature, NowMs)
        when is_reference(Table), is_binary(RelayId), byte_size(RelayId) > 0,
             byte_size(RelayId) =< 128, is_integer(TimestampMs),
             is_binary(Nonce), byte_size(Nonce) >= 16, byte_size(Nonce) =< 64,
             is_binary(Signature), byte_size(Signature) =:= 64,
             is_integer(NowMs) ->
    try ets:lookup(Table, {relay, RelayId}) of
        [] -> {error, <<"unknown_relay">>};
        [{{relay, RelayId}, PublicKey}] ->
            authenticate_known(
                Table, RelayId, PublicKey, TimestampMs, Nonce, Signature, NowMs
            )
    catch
        error:badarg -> {error, <<"closed">>}
    end;
authenticate(_Table, _RelayId, _TimestampMs, _Nonce, _Signature, _NowMs) ->
    {error, <<"invalid_hello">>}.

authenticate_known(_Table, _RelayId, _PublicKey, TimestampMs, _Nonce, _Signature, NowMs)
        when TimestampMs < NowMs - 30000; TimestampMs > NowMs + 30000 ->
    {error, <<"stale_hello">>};
authenticate_known(Table, RelayId, PublicKey, TimestampMs, Nonce, Signature, NowMs) ->
    Payload = hello_payload(RelayId, TimestampMs, Nonce),
    case verify(PublicKey, Payload, Signature) of
        false -> {error, <<"invalid_signature">>};
        true ->
            _ = remove_expired_nonces(Table, NowMs),
            NonceHash = crypto:hash(sha256, Nonce),
            Key = {nonce, RelayId, NonceHash},
            case ets:insert_new(Table, {Key, NowMs + 30000}) of
                true -> {ok, {relay_record, RelayId, <<"Ed25519">>, PublicKey}};
                false -> {error, <<"replayed_nonce">>}
            end
    end.

hello_payload(RelayId, TimestampMs, Nonce) ->
    NonceEncoded = base64url(Nonce),
    <<"beamtrace-relay-v1\nhello\n", RelayId/binary, "\n",
      (integer_to_binary(TimestampMs))/binary, "\n", NonceEncoded/binary>>.

verify(PublicKey, Payload, Signature) ->
    try crypto:verify(eddsa, none, Payload, Signature, [PublicKey, ed25519])
    catch
        _:_ -> false
    end.

remove_expired_nonces(Table, NowMs) ->
    ets:select_delete(Table, [
        {{{nonce, '_', '_'}, '$1'}, [{'<', '$1', NowMs}], [true]}
    ]).

consume_valid_key(Table, Code, PublicKey, NowMs) ->
    try ets:lookup(Table, enrollment) of
        [{enrollment, ExpectedHash, ExpiresAt, active}] ->
            PresentedHash = crypto:hash(sha256, Code),
            case crypto:hash_equals(ExpectedHash, PresentedHash) of
                false -> {error, <<"invalid_token">>};
                true when NowMs > ExpiresAt ->
                    _ = transition(Table, ExpectedHash, ExpiresAt, active, expired),
                    {error, <<"expired">>};
                true -> register_once(Table, ExpectedHash, ExpiresAt, PublicKey, NowMs)
            end;
        [{enrollment, _Hash, _ExpiresAt, registering}] ->
            {error, <<"already_used">>};
        [{enrollment, _Hash, _ExpiresAt, used}] ->
            {error, <<"already_used">>};
        [{enrollment, _Hash, _ExpiresAt, expired}] ->
            {error, <<"expired">>};
        [] ->
            {error, <<"closed">>}
    catch
        error:badarg -> {error, <<"closed">>}
    end.

register_once(Table, Hash, ExpiresAt, PublicKey, NowMs) ->
    case transition(Table, Hash, ExpiresAt, active, registering) of
        1 ->
            RelayId = <<"relay-", (hex(crypto:strong_rand_bytes(12)))/binary>>,
            [{persistence, Persist}] = ets:lookup(Table, persistence),
            case persist_identity(Persist, RelayId, PublicKey, NowMs) of
                ok ->
                    true = ets:insert(Table, {{relay, RelayId}, PublicKey}),
                    1 = transition(Table, Hash, ExpiresAt, registering, used),
                    {ok, {relay_record, RelayId, <<"Ed25519">>, PublicKey}};
                {error, Reason} ->
                    1 = transition(Table, Hash, ExpiresAt, registering, active),
                    {error, Reason}
            end;
        0 ->
            {error, <<"already_used">>}
    end.

load_relays(_Table, []) -> ok;
load_relays(Table, [{RelayId, PublicKey} | Rest])
        when is_binary(RelayId), is_binary(PublicKey), byte_size(PublicKey) =:= 32 ->
    true = ets:insert(Table, {{relay, RelayId}, PublicKey}),
    load_relays(Table, Rest);
load_relays(_Table, _Invalid) ->
    error(invalid_persisted_relay_identity).

persist_identity(Persist, RelayId, PublicKey, EnrolledAtMs) ->
    try Persist(RelayId, PublicKey, EnrolledAtMs) of
        {ok, nil} -> ok;
        {error, Reason} -> {error, Reason};
        Other -> {error, {invalid_persistence_result, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

transition(Table, Hash, ExpiresAt, From, To) ->
    ets:select_replace(Table, [
        {{enrollment, Hash, ExpiresAt, From}, [], [{{enrollment, Hash, ExpiresAt, To}}]}
    ]).

close(Table) when is_reference(Table) ->
    try ets:delete(Table)
    catch error:badarg -> true
    end,
    nil.

base64url(Binary) ->
    Encoded = base64:encode(Binary),
    UrlSafe = binary:replace(
        binary:replace(Encoded, <<"+">>, <<"-">>, [global]),
        <<"/">>, <<"_">>, [global]
    ),
    binary:replace(UrlSafe, <<"=">>, <<>>, [global]).

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>> || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
