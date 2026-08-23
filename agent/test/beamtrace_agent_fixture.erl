%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_agent_fixture).
-export([
    trigger/1,
    trigger_lifecycle/0,
    invoke/1,
    schedule_trigger/1,
    schedule_lifecycle/0,
    start_echo/0,
    stop_echo/1
]).

trigger(Target) ->
    Target ! {work, self()},
    receive
        ack -> ok
    after 1000 ->
        timeout
    end.

invoke(Target) ->
    _ = spawn(fun() -> trigger(Target) end),
    ok.

schedule_trigger(Target) ->
    _ = spawn(fun() ->
        wait_until_armed(500),
        trigger(Target)
    end),
    ok.

schedule_lifecycle() ->
    _ = spawn(fun() ->
        wait_until_armed(500),
        trigger_lifecycle()
    end),
    ok.

trigger_lifecycle() ->
    Previous = process_flag(trap_exit, true),
    Parent = self(),
    Child = spawn_link(fun() ->
        true = register(beamtrace_lifecycle_child, self()),
        Parent ! {lifecycle_ready, self()},
        receive
            crash -> exit(spawn_done)
        end
    end),
    receive
        {lifecycle_ready, Child} -> Child ! crash
    after 1000 ->
        exit(lifecycle_start_timeout)
    end,
    receive
        {'EXIT', Child, spawn_done} -> ok
    after 1000 ->
        exit(lifecycle_exit_timeout)
    end,
    _ = process_flag(trap_exit, Previous),
    ok.

start_echo() -> spawn(fun echo/0).

stop_echo(Pid) ->
    Pid ! stop,
    ok.

echo() ->
    receive
        {work, From} ->
            From ! ack,
            echo();
        stop -> ok
    end.

wait_until_armed(Attempts) when Attempts > 0 ->
    case seq_trace:get_system_tracer() of
        false ->
            timer:sleep(10),
            wait_until_armed(Attempts - 1);
        Tracer when is_pid(Tracer) ->
            case agent_is_armed(Tracer) of
                true -> ok;
                false ->
                    timer:sleep(10),
                    wait_until_armed(Attempts - 1)
            end;
        _Other ->
            timer:sleep(10),
            wait_until_armed(Attempts - 1)
    end;
wait_until_armed(0) ->
    exit(arm_timeout).

agent_is_armed(Tracer) ->
    try beamtrace_agent:status(Tracer) of
        #{armed := true} -> true;
        _ -> false
    catch
        _:_ -> false
    end.
