%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_team_store_migration_test_ffi).

-export([
    legacy_relay_store/0,
    legacy_relay_store_with_session_collision/0,
    fresh_store_path/0,
    fresh_data_dir/0
]).

fresh_store_path() ->
    unique_build_path("beamtrace-collaboration-", ".sqlite3").

fresh_data_dir() ->
    unique_build_path("beamtrace-team-collaboration-", "").

legacy_relay_store() ->
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Path = filename:join("build", "beamtrace-legacy-relay-" ++ Suffix ++ ".sqlite3"),
    ok = filelib:ensure_dir(Path),
    ok = delete_if_present(Path),
    ok = delete_if_present(Path ++ "-wal"),
    ok = delete_if_present(Path ++ "-shm"),
    {ok, Connection} = esqlite3:open(Path),
    ok = esqlite3:exec(Connection,
        "CREATE TABLE relay_frames ("
        "relay_id TEXT NOT NULL, sequence INTEGER NOT NULL, received_at_ms INTEGER NOT NULL, "
        "mode TEXT NOT NULL, blob_key TEXT NOT NULL, bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, "
        "PRIMARY KEY (relay_id, sequence));"
        "INSERT INTO relay_frames VALUES ("
        "'relay-00112233445566778899aabb', 1, 1000, 'exact', "
        "'relays/relay-00112233445566778899aabb/frames/1.json', 5, "
        "'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789');"
        "INSERT INTO relay_frames VALUES ("
        "'relay-00112233445566778899aabb', 2, 1100, 'exact', "
        "'relays/relay-00112233445566778899aabb/frames/2.json', 6, "
        "'1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef');"
        "PRAGMA user_version = 2;"),
    ok = esqlite3:close(Connection),
    unicode:characters_to_binary(filename:absname(Path)).

legacy_relay_store_with_session_collision() ->
    Path = legacy_relay_store(),
    {ok, Connection} = esqlite3:open(binary_to_list(Path)),
    ok = esqlite3:exec(Connection,
        "CREATE TABLE sessions ("
        "id TEXT PRIMARY KEY NOT NULL, project TEXT NOT NULL, environment TEXT NOT NULL, "
        "created_at_ms INTEGER NOT NULL, completeness TEXT NOT NULL, privacy TEXT NOT NULL, "
        "blob_key TEXT NOT NULL, event_count INTEGER NOT NULL);"
        "INSERT INTO sessions VALUES ("
        "'legacy-relay-00112233445566778899aabb', 'existing', 'prod', 900, "
        "'complete', 'metadata', 'sessions/existing/capture.beamtrace', 1);"),
    ok = esqlite3:close(Connection),
    Path.

delete_if_present(Path) ->
    case file:delete(Path) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} -> erlang:error({fixture_cleanup_failed, Reason})
    end.

unique_build_path(Prefix, Extension) ->
    Suffix = integer_to_list(erlang:system_time(nanosecond)) ++ "-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic])),
    Path = filename:join("build", Prefix ++ Suffix ++ Extension),
    unicode:characters_to_binary(filename:absname(Path)).
