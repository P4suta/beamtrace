%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_record_process_test_ffi).
-export([packaged_environment_isolated/0]).

packaged_environment_isolated() ->
    Names = [
        "ERL_ROOTDIR",
        "ROOTDIR",
        "ERL_LIBS",
        "BEAMTRACE_AGENT_BEAM",
        "BEAMTRACE_WEB_ROOT",
        "BEAMTRACE_BUNDLED_RUNTIME",
        "BEAMTRACE_PARENT_ERL_ROOTDIR_SET",
        "BEAMTRACE_PARENT_ERL_ROOTDIR",
        "BEAMTRACE_PARENT_ROOTDIR_SET",
        "BEAMTRACE_PARENT_ROOTDIR",
        "BEAMTRACE_PARENT_ERL_LIBS_SET",
        "BEAMTRACE_PARENT_ERL_LIBS"
    ],
    Saved = [{Name, os:getenv(Name)} || Name <- Names],
    try
        true = os:putenv("ERL_ROOTDIR", "/beamtrace-invalid-runtime"),
        true = os:putenv("ROOTDIR", "/beamtrace-invalid-runtime"),
        true = os:putenv("ERL_LIBS", "/beamtrace-invalid-libs"),
        true = os:putenv("BEAMTRACE_AGENT_BEAM", "/beamtrace-invalid-agent"),
        true = os:putenv("BEAMTRACE_WEB_ROOT", "/beamtrace-invalid-web"),
        true = os:putenv("BEAMTRACE_BUNDLED_RUNTIME", "1"),
        true = os:putenv("BEAMTRACE_PARENT_ERL_ROOTDIR_SET", "0"),
        true = os:putenv("BEAMTRACE_PARENT_ROOTDIR_SET", "0"),
        true = os:putenv("BEAMTRACE_PARENT_ERL_LIBS_SET", "0"),
        run_child()
    after
        [restore(Name, Value) || {Name, Value} <- Saved]
    end.

run_child() ->
    Expression = iolist_to_binary([
        "io:format(\"~p\", [",
        "os:getenv(\"ERL_ROOTDIR\") =/= \"/beamtrace-invalid-runtime\" andalso ",
        "os:getenv(\"ROOTDIR\") =/= \"/beamtrace-invalid-runtime\" andalso ",
        "os:getenv(\"ERL_LIBS\") =/= \"/beamtrace-invalid-libs\" andalso ",
        "os:getenv(\"BEAMTRACE_AGENT_BEAM\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_WEB_ROOT\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_BUNDLED_RUNTIME\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_ERL_ROOTDIR_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_ROOTDIR_SET\") =:= false andalso ",
        "os:getenv(\"BEAMTRACE_PARENT_ERL_LIBS_SET\") =:= false])."
    ]),
    Command = [
        <<"erl">>,
        <<"-noshell">>,
        <<"-eval">>,
        Expression,
        <<"-s">>,
        <<"init">>,
        <<"stop">>
    ],
    case beamtrace_cli_ffi:start_gated_command(
        Command,
        <<"beamtrace_env_test@localhost">>,
        <<"beamtrace_env_cookie">>
    ) of
        {ok, Handle} ->
            {ok, nil} = beamtrace_cli_ffi:release_gated_command(Handle),
            {ok, nil} = beamtrace_cli_ffi:release_gated_command_finish(Handle),
            case beamtrace_cli_ffi:await_gated_command(Handle, 5000) of
                {ok, {0, Output}} -> {ok, Output};
                Other ->
                    {error, unicode:characters_to_binary(io_lib:format("~0p", [Other]))}
            end;
        Error -> Error
    end.

restore(Name, false) -> os:unsetenv(Name);
restore(Name, Value) -> os:putenv(Name, Value).
