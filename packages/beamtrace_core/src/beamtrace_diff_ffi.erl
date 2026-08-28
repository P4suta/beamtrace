%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_diff_ffi).

-export([
    compact_base/2,
    refine_round/4,
    signature_cache_new/0,
    signature_cache_put/3,
    signature_cache_get/2,
    signature_cache_delete/1
]).

-define(FINGERPRINT_MODULUS, 2147483647).

%% Keep transient alignment strings off the preparing process heap while the
%% four fingerprint rounds allocate their maps. The owning process remains the
%% only reader and ETS also removes the table automatically if that process exits.
signature_cache_new() ->
    ets:new(?MODULE, [set, private]).

signature_cache_put(Cache, Position, Signature) ->
    true = ets:insert(Cache, {Position, Signature}),
    nil.

signature_cache_get(Cache, Position) ->
    ets:lookup_element(Cache, Position, 2).

signature_cache_delete(Cache) ->
    true = ets:delete(Cache),
    nil.

compact_base(Root, Signature) ->
    hash_parts([Root, <<"|">>, Signature], 17).

refine_round(Fingerprints, Incoming, Outgoing, _Ids) ->
    maps:map(fun(Id, Current) ->
        Before = neighbor_fingerprints(Id, Incoming, Fingerprints),
        After = neighbor_fingerprints(Id, Outgoing, Fingerprints),
        compact_refined(Current, Before, After)
    end, Fingerprints).

neighbor_fingerprints(Id, Adjacency, Fingerprints) ->
    case maps:get(Id, Adjacency, []) of
        [] -> [];
        [Neighbor] -> [maps:get(Neighbor, Fingerprints, 0)];
        Neighbors ->
            Values = [maps:get(Neighbor, Fingerprints, 0)
                      || Neighbor <- Neighbors],
            lists:sort(fun lexical_fingerprint/2, Values)
    end.

lexical_fingerprint(Left, Right) ->
    integer_to_binary(Left) =< integer_to_binary(Right).

compact_refined(Current, Before, After) ->
    Hash0 = hash_decimal(Current, 17),
    Hash1 = hash_bytes(<<"<">>, Hash0),
    Hash2 = hash_joined(Before, Hash1),
    Hash3 = hash_bytes(<<">">>, Hash2),
    hash_joined(After, Hash3).

hash_parts([], Hash) -> Hash;
hash_parts([Part | Rest], Hash) ->
    hash_parts(Rest, hash_bytes(Part, Hash)).

hash_joined([], Hash) -> Hash;
hash_joined([First | Rest], Hash) ->
    hash_joined_tail(Rest, hash_decimal(First, Hash)).

hash_joined_tail([], Hash) -> Hash;
hash_joined_tail([Value | Rest], Hash) ->
    Next = hash_decimal(Value, hash_bytes(<<",">>, Hash)),
    hash_joined_tail(Rest, Next).

hash_decimal(Value, Hash) ->
    hash_bytes(integer_to_binary(Value), Hash).

%% Fold UTF-8 code points directly from the binary. This preserves the public
%% fingerprint polynomial while avoiding a code-point list allocation.
hash_bytes(<<>>, Hash) -> Hash;
hash_bytes(<<A, B, C, Rest/binary>>, Hash)
        when A < 128, B < 128, C < 128 ->
    %% Three ASCII code points can be combined with one remainder while the
    %% intermediate stays within a 64-bit Erlang small integer. Canonical
    %% signatures are overwhelmingly ASCII; non-ASCII input falls through to
    %% the exact UTF-8 code-point clause below.
    Next = (
        Hash * 2248091
        + A * 17161
        + B * 131
        + C
    ) rem ?FINGERPRINT_MODULUS,
    hash_bytes(Rest, Next);
hash_bytes(<<Codepoint/utf8, Rest/binary>>, Hash) ->
    Next = (Hash * 131 + Codepoint) rem ?FINGERPRINT_MODULUS,
    hash_bytes(Rest, Next).
