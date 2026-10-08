%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_project_config_discovery_tests).

-include_lib("eunit/include/eunit.hrl").

discovery_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun finds_the_configuration_in_a_parent_directory/1,
        fun stops_at_a_git_repository_boundary/1,
        fun stops_at_a_git_worktree_file_boundary/1,
        fun prefers_the_nearest_configuration/1
    ]}.

setup() ->
    %% These tests change the working directory, which breaks lazy loading
    %% from relative code paths — load the module under test up front.
    {module, _} = code:ensure_loaded(beamtrace_project_config_ffi),
    {ok, Previous} = file:get_cwd(),
    Root = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "beamtrace-discovery-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Nested = filename:join([Root, "apps", "web", "src"]),
    ok = filelib:ensure_path(Nested),
    #{previous => Previous, root => Root, nested => Nested}.

cleanup(#{previous := Previous, root := Root}) ->
    ok = file:set_cwd(Previous),
    _ = file:del_dir_r(Root),
    ok.

write_config(Directory, Marker) ->
    ok = file:write_file(
        filename:join(Directory, "beamtrace.toml"),
        <<"[defaults]\nmax_roots = ", Marker/binary, "\n">>
    ).

finds_the_configuration_in_a_parent_directory(#{root := Root, nested := Nested}) ->
    fun() ->
        write_config(Root, <<"3">>),
        ok = file:set_cwd(Nested),
        {ok, {some, {Path, Contents}}} = beamtrace_project_config_ffi:load(),
        ?assertEqual(
            unicode:characters_to_binary(filename:join(Root, "beamtrace.toml")),
            Path
        ),
        ?assert(binary:match(Contents, <<"max_roots = 3">>) =/= nomatch)
    end.

stops_at_a_git_repository_boundary(#{root := Root, nested := Nested}) ->
    fun() ->
        %% The configuration above the repository root must not be found.
        write_config(Root, <<"3">>),
        Repository = filename:join(Root, "apps"),
        ok = filelib:ensure_path(filename:join(Repository, ".git")),
        ok = file:set_cwd(Nested),
        ?assertEqual({ok, none}, beamtrace_project_config_ffi:load())
    end.

stops_at_a_git_worktree_file_boundary(#{root := Root, nested := Nested}) ->
    fun() ->
        write_config(Root, <<"3">>),
        Repository = filename:join(Root, "apps"),
        ok = file:write_file(
            filename:join(Repository, ".git"),
            <<"gitdir: elsewhere\n">>
        ),
        ok = file:set_cwd(Nested),
        ?assertEqual({ok, none}, beamtrace_project_config_ffi:load())
    end.

prefers_the_nearest_configuration(#{root := Root, nested := Nested}) ->
    fun() ->
        write_config(Root, <<"3">>),
        write_config(filename:join(Root, "apps"), <<"7">>),
        ok = file:set_cwd(Nested),
        {ok, {some, {Path, Contents}}} = beamtrace_project_config_ffi:load(),
        ?assert(binary:match(Path, <<"apps">>) =/= nomatch),
        ?assert(binary:match(Contents, <<"max_roots = 7">>) =/= nomatch)
    end.
