%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_completion_test_ffi).

-export([probe/3]).

%% Source a generated completion script in a real shell and print the
%% candidates for one command line. Returns `skipped` when the shell is not
%% installed unless BEAMTRACE_REQUIRE_SHELLS names it.
probe(Shell, Script, Line) when is_binary(Shell), is_binary(Script), is_binary(Line) ->
    ShellName = normalize(binary_to_list(Shell)),
    case {os:find_executable(executable(ShellName)), probe_supported(ShellName)} of
        {false, _} -> skipped(ShellName);
        {_, false} -> skipped(ShellName);
        {Executable, true} ->
            Path = script_path(ShellName),
            case file:write_file(Path, Script) of
                {error, Reason} ->
                    _ = file:delete(Path),
                    {error, unicode:characters_to_binary(io_lib:format(
                        "could not write ~s: ~p", [Path, Reason]))};
                ok ->
                    try
                        run(Executable, ShellName, Path, binary_to_list(Line))
                    after
                        _ = file:delete(Path)
                    end
            end
    end.

normalize("pwsh") -> "powershell";
normalize(Shell) -> Shell.

%% TabExpansion2 does not consult native completers on the Windows runners,
%% so the PowerShell probe is only run there when it is explicitly required.
probe_supported("powershell") ->
    case os:type() of
        {win32, _} -> required("powershell");
        _ -> true
    end;
probe_supported(_Shell) -> true.

required(ShellName) ->
    Required = case os:getenv("BEAMTRACE_REQUIRE_SHELLS") of
        false -> [];
        Value -> string:lexemes(Value, ", ")
    end,
    lists:member(ShellName, Required).

executable("powershell") -> "pwsh";
executable(Shell) -> Shell.

skipped(ShellName) ->
    case required(ShellName) of
        true -> {error, unicode:characters_to_binary(ShellName ++ " is required but not available")};
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

%% The command line and script path travel as positional arguments or
%% environment values; each shell parses them itself.
run(Executable, "bash", Path, Line) ->
    Script = "source \"$1\"; read -r -a COMP_WORDS <<<\"$2\"; "
        "case \"$2\" in *' ') COMP_WORDS+=('');; esac; "
        "COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 )); _beamtrace; "
        "printf '%s\\n' \"${COMPREPLY[@]}\"",
    command(Executable, ["--noprofile", "--norc", "-c", Script, "_", Path, Line]);
run(Executable, "zsh", Path, _Line) ->
    command(Executable, ["-n", Path]);
run(Executable, "fish", Path, Line) ->
    command(Executable, ["--no-config", "-c",
        "source \"$argv[1]\"; complete -C \"$argv[2]\"", Path, Line]);
run(Executable, "powershell", Path, Line) ->
    Column = integer_to_list(length(Line)),
    command(Executable, ["-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass", "-Command",
        ". $env:BEAMTRACE_PROBE_SCRIPT; (TabExpansion2 -inputScript $env:BEAMTRACE_PROBE_LINE"
        " -cursorColumn " ++ Column ++ ").CompletionMatches | ForEach-Object { $_.CompletionText }"],
        [{"BEAMTRACE_PROBE_SCRIPT", Path}, {"BEAMTRACE_PROBE_LINE", Line}]).

command(Executable, Arguments) ->
    command(Executable, Arguments, []).

command(Executable, Arguments, Environment) ->
    Port = open_port({spawn_executable, Executable},
        [binary, exit_status, stderr_to_stdout, use_stdio,
         {args, Arguments}, {env, Environment}]),
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
