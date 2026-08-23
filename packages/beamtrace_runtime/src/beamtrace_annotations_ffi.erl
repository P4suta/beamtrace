%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_annotations_ffi).

-export([new/0, append/5, list/1, close/1]).

new() ->
    Store = ets:new(beamtrace_annotations, [
        ordered_set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    true = ets:insert(Store, {counter, 0}),
    Store.

append(Store, EventId, Text, Author, CreatedAtMs)
        when is_reference(Store), is_binary(EventId), is_binary(Text),
             is_binary(Author), is_integer(CreatedAtMs) ->
    Sequence = ets:update_counter(Store, counter, 1),
    Id = <<"annotation-", (integer_to_binary(Sequence))/binary>>,
    Annotation = {annotation, Id, EventId, Text, Author, CreatedAtMs},
    true = ets:insert(Store, {{annotation, Sequence}, Annotation}),
    Annotation.

list(Store) when is_reference(Store) ->
    try
        [Annotation || {{annotation, _Sequence}, Annotation} <- ets:tab2list(Store)]
    catch
        error:badarg -> []
    end.

close(Store) when is_reference(Store) ->
    try ets:delete(Store), nil
    catch error:badarg -> nil
    end.
