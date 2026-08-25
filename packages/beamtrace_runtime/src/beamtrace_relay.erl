%% SPDX-License-Identifier: Apache-2.0 OR MIT
%%
%% Narrow relay boundary for agent injection. This module intentionally does
%% not expose a general-purpose RPC function.
-module(beamtrace_relay).

-export([
    agent_binary/0,
    probe/1,
    sample_processes/3,
    search_mfas/3,
    inject/1,
    inject/2,
    start_agent/3,
    arm_agent/3,
    capture_agent_status/1,
    listen_agent/3,
    grant/3,
    seal_agent/4,
    stop_agent/2,
    unload/3,
    unload_unstarted/2
]).

-define(RPC_TIMEOUT, 10000).
-define(AGENT_PROTOCOL_VERSION, 2).
-define(AGENT_MODULE_HASH, <<"d62f3f5a-beamtrace-agent-v3-seal-receipt">>).
-define(REQUIRED_AGENT_EXPORTS, [
    {version, 0},
    {start, 2},
    {arm, 2},
    {listen, 2},
    {grant, 2},
    {seal, 3},
    {stop, 1}
]).

agent_binary() ->
    case os:getenv("BEAMTRACE_AGENT_BEAM") of
        false -> loaded_agent_binary();
        Filename -> configured_agent_binary(Filename)
    end.

configured_agent_binary(Filename) ->
    case file:read_file(Filename) of
        {ok, Beam} ->
            case validate_agent_beam(Beam) of
                ok ->
                    {ok, Beam, Filename, crypto:hash(sha256, Beam)};
                {error, Reason} ->
                    {error, {invalid_agent_beam, Reason}}
            end;
        {error, Reason} ->
            {error, {agent_beam_read_failed, Reason}}
    end.

loaded_agent_binary() ->
    case code:get_object_code(beamtrace_agent) of
        {beamtrace_agent, Beam, Filename} when is_binary(Beam) ->
            case validate_agent_beam(Beam) of
                ok -> {ok, Beam, Filename, crypto:hash(sha256, Beam)};
                {error, Reason} -> {error, {invalid_agent_beam, Reason}}
            end;
        error ->
            {error, agent_beam_unavailable}
    end.

validate_agent_beam(Beam) ->
    case beam_lib:chunks(Beam, [exports]) of
        {ok, {beamtrace_agent, [{exports, Exports}]}} ->
            case [Export || Export <- ?REQUIRED_AGENT_EXPORTS,
                            not lists:member(Export, Exports)] of
                [] -> ok;
                Missing -> {error, {missing_exports, Missing}}
            end;
        {ok, {Module, _Chunks}} ->
            {error, {wrong_module, Module}};
        {error, beam_lib, Reason} ->
            {error, {malformed_beam, Reason}};
        Other ->
            {error, {malformed_beam, Other}}
    end.

probe(Node) when is_atom(Node) ->
    case target_otp_supported(Node) of
        ok ->
            case safe_erpc(Node, erlang, system_info, [otp_release]) of
                {ok, Release} ->
                    #{
                        node => Node,
                        otp_release => iolist_to_binary(Release),
                        arbitrary_rpc => false
                    };
                {error, Reason} -> {error, {node_unreachable, Reason}}
            end;
        Error -> Error
    end.

sample_processes(Node, Offset, Limit)
        when is_atom(Node), is_integer(Offset), Offset >= 0,
             is_integer(Limit), Limit > 0, Limit =< 1000 ->
    case safe_erpc(Node, erlang, processes, []) of
        {ok, Pids} when is_list(Pids) ->
            sample_process_slice(Node, Pids, Offset, Limit);
        {ok, Other} -> {error, {unexpected_process_list, Other}};
        {error, Reason} -> {error, {sample_failed, Reason}}
    end;
sample_processes(_Node, _Offset, _Limit) ->
    {error, invalid_sample_window}.

search_mfas(Node, Query, Limit)
        when is_atom(Node), is_binary(Query), byte_size(Query) =< 256,
             is_integer(Limit), Limit > 0, Limit =< 200 ->
    case safe_erpc(Node, code, all_loaded, []) of
        {ok, Loaded} when is_list(Loaded) ->
            Modules = lists:sort([Module || {Module, _Filename} <- Loaded, is_atom(Module)]),
            {ok, search_modules(Node, Modules, string:lowercase(Query), Limit, [])};
        {ok, Other} -> {error, {unexpected_module_list, Other}};
        {error, Reason} -> {error, {mfa_search_failed, Reason}}
    end;
search_mfas(_Node, _Query, _Limit) ->
    {error, invalid_mfa_search}.

search_modules(_Node, _Modules, _Query, 0, Accumulator) ->
    lists:reverse(Accumulator);
search_modules(_Node, [], _Query, _Remaining, Accumulator) ->
    lists:reverse(Accumulator);
search_modules(Node, [Module | Rest], Query, Remaining, Accumulator) ->
    ModuleBinary = atom_to_binary(Module, utf8),
    case module_may_match(ModuleBinary, Query) of
        false -> search_modules(Node, Rest, Query, Remaining, Accumulator);
        true ->
            case safe_erpc(Node, Module, module_info, [exports]) of
                {ok, Exports} when is_list(Exports) ->
                    {NextRemaining, NextAccumulator} = add_matching_exports(
                        ModuleBinary,
                        Exports,
                        Query,
                        Remaining,
                        Accumulator
                    ),
                    search_modules(Node, Rest, Query, NextRemaining, NextAccumulator);
                _ -> search_modules(Node, Rest, Query, Remaining, Accumulator)
            end
    end.

module_may_match(_Module, <<>>) -> true;
module_may_match(Module, Query) ->
    case binary:split(Query, <<":">>) of
        [ModuleQuery, _FunctionQuery] when byte_size(ModuleQuery) > 0 ->
            binary:match(string:lowercase(Module), ModuleQuery) =/= nomatch;
        _ -> true
    end.

add_matching_exports(_Module, _Exports, _Query, 0, Accumulator) ->
    {0, Accumulator};
add_matching_exports(_Module, [], _Query, Remaining, Accumulator) ->
    {Remaining, Accumulator};
add_matching_exports(Module, [{module_info, _Arity} | Rest], Query, Remaining, Accumulator) ->
    add_matching_exports(Module, Rest, Query, Remaining, Accumulator);
add_matching_exports(Module, [{Function, Arity} | Rest], Query, Remaining, Accumulator)
        when is_atom(Function), is_integer(Arity), Arity >= 0 ->
    FunctionBinary = atom_to_binary(Function, utf8),
    Candidate = <<Module/binary, ":", FunctionBinary/binary, "/",
        (integer_to_binary(Arity))/binary>>,
    case Query =:= <<>> orelse binary:match(string:lowercase(Candidate), Query) =/= nomatch of
        true ->
            add_matching_exports(
                Module,
                Rest,
                Query,
                Remaining - 1,
                [#{module => Module, function => FunctionBinary, arity => Arity} | Accumulator]
            );
        false -> add_matching_exports(Module, Rest, Query, Remaining, Accumulator)
    end;
add_matching_exports(Module, [_Invalid | Rest], Query, Remaining, Accumulator) ->
    add_matching_exports(Module, Rest, Query, Remaining, Accumulator).

sample_process_slice(_Node, [], _Offset, _Limit) -> {ok, [], 0};
sample_process_slice(Node, Pids, Offset, Limit) ->
    Count = length(Pids),
    Start = Offset rem Count,
    Window = lists:sublist(lists:nthtail(Start, Pids), Limit),
    Samples = lists:filtermap(fun(Pid) -> sample_process(Node, Pid) end, Window),
    Next = case Start + length(Window) >= Count of
        true -> 0;
        false -> Start + length(Window)
    end,
    {ok, Samples, Next}.

sample_process(Node, Pid) ->
    Keys = [
        registered_name,
        label,
        initial_call,
        message_queue_len,
        memory,
        reductions,
        heap_size,
        total_heap_size,
        links,
        {dictionary, '$ancestors'},
        status,
        current_function
    ],
    case safe_erpc(Node, erlang, process_info, [Pid, Keys]) of
        {ok, undefined} -> false;
        {ok, Info} when is_list(Info) ->
            {true, #{
                pid => list_to_binary(pid_to_list(Pid)),
                node => atom_to_binary(Node, utf8),
                registered_name => safe_registered_name(Info),
                process_label => safe_process_label(Info),
                initial_call => proplists:get_value(initial_call, Info, undefined),
                message_queue_len => proplists:get_value(message_queue_len, Info, 0),
                memory => proplists:get_value(memory, Info, 0),
                reductions => proplists:get_value(reductions, Info, 0),
                heap_size => proplists:get_value(heap_size, Info, 0),
                total_heap_size => proplists:get_value(total_heap_size, Info, 0),
                link_count => length(proplists:get_value(links, Info, [])),
                links => safe_links(Info),
                ancestors => safe_ancestors(Info),
                status => proplists:get_value(status, Info, undefined),
                current_function => proplists:get_value(current_function, Info, undefined)
            }};
        _ -> false
    end.

safe_registered_name(Info) ->
    case proplists:get_value(registered_name, Info, []) of
        [] -> undefined;
        Name when is_atom(Name) -> atom_to_binary(Name, utf8);
        _ -> undefined
    end.

safe_process_label(Info) ->
    safe_identity_text(proplists:get_value(label, Info, undefined)).

safe_links(Info) ->
    [list_to_binary(pid_to_list(Pid))
        || Pid <- proplists:get_value(links, Info, []), is_pid(Pid)].

safe_ancestors(Info) ->
    case proplists:get_value({dictionary, '$ancestors'}, Info, undefined) of
        Ancestors when is_list(Ancestors) ->
            lists:sublist([
                Text || Ancestor <- Ancestors,
                        Text <- [safe_identity_text(Ancestor)],
                        Text =/= undefined
            ], 32);
        _ -> []
    end.

safe_identity_text(undefined) -> undefined;
safe_identity_text(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
safe_identity_text(Value) when is_pid(Value) -> list_to_binary(pid_to_list(Value));
safe_identity_text(Value) when is_binary(Value), byte_size(Value) =< 256 -> Value;
safe_identity_text(Value) when is_list(Value) ->
    try
        Binary = unicode:characters_to_binary(Value),
        case byte_size(Binary) =< 256 of
            true -> Binary;
            false -> undefined
        end
    catch _:_ -> undefined
    end;
safe_identity_text(_Value) -> undefined.

inject(Node) when is_atom(Node) ->
    case agent_binary() of
        {ok, Beam, _Filename, _Digest} -> inject(Node, Beam);
        Error -> Error
    end.

inject(Node, Beam) when is_atom(Node), is_binary(Beam) ->
    Digest = crypto:hash(sha256, Beam),
    case target_otp_supported(Node) of
        ok -> inject_supported(Node, Beam, Digest);
        Error -> Error
    end.

inject_supported(Node, Beam, Digest) ->
    case remote_loaded_identity(Node) of
        not_loaded ->
            case safe_erpc(Node, code, load_binary, [
                beamtrace_agent,
                "beamtrace_agent.beam",
                Beam
            ]) of
                {ok, {module, beamtrace_agent}} ->
                    verify_loaded(Node, Digest, loaded);
                {ok, Other} ->
                    {error, {load_failed, Other}};
                {error, Reason} ->
                    {error, {load_failed, Reason}}
            end;
        {loaded, Digest, Version} when is_map(Version) ->
            {ok, reused, Digest};
        {loaded_version, Version} ->
            case compatible_version(Version) of
                true -> {ok, reused, Digest};
                false -> {error, {agent_conflict, Version}}
            end;
        {loaded, ExistingDigest, _Version} ->
            {error, {agent_conflict, ExistingDigest}};
        {loaded_unknown, Identity} ->
            {error, {agent_conflict, Identity}};
        {error, Reason} ->
            {error, Reason}
    end.

verify_loaded(Node, ExpectedDigest, Disposition) ->
    case remote_loaded_identity(Node) of
        {loaded, ExpectedDigest, Version} when is_map(Version) ->
            case maps:get(protocol, Version, undefined) of
                ?AGENT_PROTOCOL_VERSION -> {ok, Disposition, ExpectedDigest};
                Protocol -> {error, {protocol_mismatch, Protocol}}
            end;
        {loaded_version, Version} ->
            case compatible_version(Version) of
                true -> {ok, Disposition, ExpectedDigest};
                false -> {error, {agent_verification_failed, Version}}
            end;
        {loaded, ActualDigest, _Version} ->
            {error, {agent_hash_mismatch, ActualDigest}};
        Other ->
            {error, {agent_verification_failed, Other}}
    end.

start_agent(Node, Owner, Options)
        when is_atom(Node), is_pid(Owner), is_map(Options) ->
    case safe_erpc(Node, beamtrace_agent, start, [Owner, Options]) of
        {ok, {ok, Agent}} when is_pid(Agent) -> {ok, Agent};
        {ok, Other} -> {error, {agent_start_failed, Other}};
        {error, Reason} -> {error, {agent_start_failed, Reason}}
    end.

arm_agent(Node, Agent, MFA)
        when is_atom(Node), is_pid(Agent), is_tuple(MFA) ->
    case safe_erpc(Node, beamtrace_agent, arm, [Agent, MFA]) of
        {ok, Result} -> Result;
        {error, Reason} -> {error, {agent_arm_failed, Reason}}
    end.

capture_agent_status(Node) when is_atom(Node) ->
    case safe_erpc(Node, seq_trace, get_system_tracer, []) of
        {ok, false} -> {error, not_armed};
        {ok, Agent} when is_pid(Agent) ->
            case safe_erpc(Node, beamtrace_agent, status, [Agent]) of
                {ok, #{armed := true}} -> {ok, armed};
                {ok, _Status} -> {error, not_armed};
                {error, _Reason} -> {error, system_tracer_occupied}
            end;
        {ok, _Existing} -> {error, system_tracer_occupied};
        {error, Reason} -> {error, Reason}
    end.

listen_agent(Node, Agent, Label)
        when is_atom(Node), is_pid(Agent), is_integer(Label), Label >= 0 ->
    case safe_erpc(Node, beamtrace_agent, listen, [Agent, Label]) of
        {ok, Result} -> Result;
        {error, Reason} -> {error, {agent_listen_failed, Reason}}
    end.

grant(Node, Agent, Credits)
        when is_atom(Node), is_pid(Agent), is_integer(Credits), Credits >= 0 ->
    case safe_erpc(Node, beamtrace_agent, grant, [Agent, Credits]) of
        {ok, Result} -> Result;
        {error, Reason} -> {error, {agent_grant_failed, Reason}}
    end.

seal_agent(Node, Agent, Reason, DrainTimeoutMs)
        when is_atom(Node), is_pid(Agent),
             is_integer(DrainTimeoutMs), DrainTimeoutMs >= 1000,
             DrainTimeoutMs =< 60000 ->
    case safe_erpc_timeout(
        Node,
        beamtrace_agent,
        seal,
        [Agent, Reason, DrainTimeoutMs],
        DrainTimeoutMs + 2000
    ) of
        {ok, Result} -> Result;
        {error, Reason} -> {error, {agent_seal_failed, Reason}}
    end.

stop_agent(Node, Agent) when is_atom(Node), is_pid(Agent) ->
    case safe_erpc(Node, beamtrace_agent, stop, [Agent]) of
        {ok, ok} -> ok;
        {error, {exception, exit, {noproc, _}, _}} -> ok;
        {error, {exception, exit, noproc, _}} -> ok;
        {ok, Other} -> {error, {agent_stop_failed, Other}};
        {error, Reason} -> {error, {agent_stop_failed, Reason}}
    end.

unload(Node, ExpectedDigest, Agent)
        when is_atom(Node), is_binary(ExpectedDigest), is_pid(Agent) ->
    case remote_process_alive(Node, Agent) of
        true ->
            {error, {agent_active, Agent}};
        false ->
            unload_inactive(Node, ExpectedDigest);
        {error, Reason} ->
            {error, {agent_liveness_failed, Reason}}
    end.

%% Used only when start_agent/3 returned an error and therefore no agent pid is
%% available. soft_purge is the safety check: code is never deleted while an
%% unexpected process is still executing it.
unload_unstarted(Node, ExpectedDigest)
        when is_atom(Node), is_binary(ExpectedDigest) ->
    unload_inactive(Node, ExpectedDigest).

unload_inactive(Node, ExpectedDigest) ->
    case remote_loaded_identity(Node) of
        not_loaded -> ok;
        {loaded, ExpectedDigest, Version} when is_map(Version) ->
            case safe_erpc(Node, code, soft_purge, [beamtrace_agent]) of
                {ok, true} -> delete_agent(Node);
                {ok, false} -> {error, agent_code_in_use};
                {error, Reason} -> {error, {purge_failed, Reason}}
            end;
        {loaded_version, Version} ->
            case compatible_version(Version) of
                true ->
                    case safe_erpc(Node, code, soft_purge, [beamtrace_agent]) of
                        {ok, true} -> delete_agent(Node);
                        {ok, false} -> {error, agent_code_in_use};
                        {error, Reason} -> {error, {purge_failed, Reason}}
                    end;
                false -> {error, {agent_conflict, Version}}
            end;
        {loaded, ExistingDigest, _Version} ->
            {error, {agent_conflict, ExistingDigest}};
        {loaded_unknown, Identity} ->
            {error, {agent_conflict, Identity}};
        {error, Reason} ->
            {error, Reason}
    end.

delete_agent(Node) ->
    case safe_erpc(Node, code, delete, [beamtrace_agent]) of
        {ok, true} -> ok;
        {ok, false} -> {error, agent_delete_failed};
        {error, Reason} -> {error, {agent_delete_failed, Reason}}
    end.

remote_process_alive(Node, Pid) ->
    case safe_erpc(Node, erlang, is_process_alive, [Pid]) of
        {ok, Value} when is_boolean(Value) -> Value;
        {error, Reason} -> {error, Reason};
        {ok, Other} -> {error, {unexpected_liveness, Other}}
    end.

remote_loaded_identity(Node) ->
    case safe_erpc(Node, code, is_loaded, [beamtrace_agent]) of
        {ok, false} ->
            not_loaded;
        {ok, _Loaded} ->
            Version = remote_version(Node),
            case safe_erpc(Node, code, get_object_code, [beamtrace_agent]) of
                {ok, {beamtrace_agent, Beam, _Filename}} when is_binary(Beam) ->
                    {loaded, crypto:hash(sha256, Beam), Version};
                _ when is_map(Version) ->
                    {loaded_version, Version};
                _ ->
                    {loaded_unknown, Version}
            end;
        {error, Reason} ->
            {error, {is_loaded_failed, Reason}}
    end.

remote_version(Node) ->
    case safe_erpc(Node, beamtrace_agent, version, []) of
        {ok, Version} -> Version;
        {error, Reason} -> {version_unavailable, Reason}
    end.

compatible_version(Version) when is_map(Version) ->
    maps:get(protocol, Version, undefined) =:= ?AGENT_PROTOCOL_VERSION
        andalso maps:get(module_hash, Version, undefined) =:= ?AGENT_MODULE_HASH;
compatible_version(_Version) ->
    false.

target_otp_supported(Node) ->
    case safe_erpc(Node, erlang, system_info, [otp_release]) of
        {ok, Release} ->
            case parse_release(Release) of
                Major when is_integer(Major), Major >= 27 -> ok;
                Major when is_integer(Major) -> {error, {unsupported_otp, Major}};
                error -> {error, {invalid_otp_release, Release}}
            end;
        {error, Reason} ->
            {error, {node_unreachable, Reason}}
    end.

parse_release(Binary) when is_binary(Binary) ->
    try binary_to_integer(Binary)
    catch _:_ -> error
    end;
parse_release(String) when is_list(String) ->
    try list_to_integer(String)
    catch _:_ -> error
    end;
parse_release(_Other) -> error.

safe_erpc(Node, Module, Function, Arguments) ->
    safe_erpc_timeout(Node, Module, Function, Arguments, ?RPC_TIMEOUT).

safe_erpc_timeout(Node, Module, Function, Arguments, Timeout) ->
    try erpc:call(Node, Module, Function, Arguments, Timeout) of
        Value -> {ok, Value}
    catch
        Class:Reason:Stacktrace -> {error, {exception, Class, Reason, Stacktrace}}
    end.
