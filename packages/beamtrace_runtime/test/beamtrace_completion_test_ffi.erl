%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_completion_test_ffi).

-export([probe/3]).

%% Source a generated completion script in a real shell and print the
%% candidates for one command line. Returns `skipped` when the shell is not
%% installed unless BEAMTRACE_REQUIRE_SHELLS names it.
probe(Shell, Script, Line) when is_binary(Shell), is_binary(Script), is_binary(Line) ->
    ShellName = binary_to_list(Shell),
    case os:find_executable(executable(ShellName)) of
        false -> skipped(ShellName);
        Executable ->
            Path = script_path(ShellName),
            ok = file:write_file(Path, Script),
            try
                run(Executable, ShellName, Path, binary_to_list(Line))
            after
                _ = file:delete(Path)
            end
    end.

executable("powershell") -> "pwsh";
executable(Shell) -> Shell.

skipped(ShellName) ->
    Required = case os:getenv("BEAMTRACE_REQUIRE_SHELLS") of
        false -> [];
        Value -> string:lexemes(Value, ", ")
    end,
    case lists:member(ShellName, Required) of
        true -> {error, unicode:characters_to_binary(ShellName ++ " is required but not installed")};
        false -> {ok, <<"skipped">>}
    end.

script_path(ShellName) ->
    Candidates = [os:getenv(Name) || Name <- ["TMPDIR", "TEMP", "TMP"]],
    Root = case [Value || Value <- Candidates, Value =/= false, Value =/= []] of
        [First | _] -> First;
        [] ->
            case os:type() of
                {win32, _} -> filename:absname(".");
                _ -> "/tmp"
            end
    end,
    filename:join(Root, "beamtrace-completion-" ++ ShellName ++ "-"
        ++ integer_to_list(erlang:unique_integer([positive]))
        ++ extension(ShellName)).

extension("powershell") -> ".ps1";
extension("fish") -> ".fish";
extension("zsh") -> ".zsh";
extension(_) -> ".bash".

run(Executable, "bash", Path, Line) ->
    Words = string:split(Line, " ", all),
    Cword = length(Words) - 1,
    Script = "source \"$1\"; COMP_WORDS=(" ++ string:join([quote(W) || W <- Words], " ")
        ++ "); COMP_CWORD=" ++ integer_to_list(Cword)
        ++ "; _beamtrace; printf '%s\\n' \"${COMPREPLY[@]}\"",
    command(Executable, ["--noprofile", "--norc", "-c", Script, "_", Path]);
run(Executable, "zsh", Path, _Line) ->
    command(Executable, ["-n", Path]);
run(Executable, "fish", Path, Line) ->
    command(Executable, ["--no-config", "-c",
        "source " ++ Path ++ "; complete -C '" ++ Line ++ "'"]);
run(Executable, "powershell", Path, Line) ->
    Column = integer_to_list(length(Line)),
    command(Executable, ["-NoProfile", "-NonInteractive", "-Command",
        ". '" ++ Path ++ "'; (TabExpansion2 -inputScript '" ++ Line
        ++ "' -cursorColumn " ++ Column ++ ").CompletionMatches | ForEach-Object { $_.CompletionText }"]).

quote(Word) -> "'" ++ Word ++ "'".

command(Executable, Arguments) ->
    Port = open_port({spawn_executable, Executable},
        [binary, exit_status, stderr_to_stdout, use_stdio, {args, Arguments}]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, unicode:characters_to_binary(io_lib:format(
                "shell exited with ~B: ~ts", [Status, Acc]))}
    after 30000 ->
        catch port_close(Port),
        {error, <<"completion probe timed out">>}
    end.
