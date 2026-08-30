%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_server_ffi).
-behaviour(gen_event).

-export([
    await_shutdown/1,
    begin_listener_start/0,
    end_listener_start/1,
    stop_worker/1,
    stop_listener/1,
    open_browser/1
]).
-export([
    init/1,
    handle_event/2,
    handle_call/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

await_shutdown(Listener) when is_pid(Listener) ->
    Monitor = erlang:monitor(process, Listener),
    Handler = {?MODULE, make_ref()},
    case install_signal_handler(Handler, self()) of
        {ok, Installation} ->
            await_shutdown_event(Listener, Monitor, Handler, Installation);
        {error, Reason} ->
            erlang:demonitor(Monitor, [flush]),
            {error, reason_binary({signal_handler_failed, Reason})}
    end;
await_shutdown(_Listener) ->
    {error, <<"invalid_listener">>}.

begin_listener_start() ->
    erlang:process_flag(trap_exit, true).

end_listener_start(Previous) when is_boolean(Previous) ->
    _ = erlang:process_flag(trap_exit, Previous),
    nil.

await_shutdown_event(Listener, Monitor, Handler, Installation) ->
    Result = receive
        {beamtrace_shutdown, sigint} -> {ok, nil};
        {beamtrace_shutdown, sigterm} -> {ok, nil};
        {'DOWN', Monitor, process, Listener, Reason} ->
            {error, reason_binary({listener_stopped, Reason})}
    end,
    restore_signal_handler(Handler, Installation),
    erlang:demonitor(Monitor, [flush]),
    Result.

install_signal_handler(Handler, Owner) ->
    case os:type() of
        {unix, _} ->
            ok = os:set_signal(sigterm, handle),
            case lists:member(
                erl_signal_handler,
                gen_event:which_handlers(erl_signal_server)
            ) of
                true ->
                    case gen_event:swap_handler(
                        erl_signal_server,
                        {erl_signal_handler, beamtrace},
                        {Handler, Owner}
                    ) of
                        ok -> {ok, swapped_default};
                        Error -> Error
                    end;
                false ->
                    case gen_event:add_handler(
                        erl_signal_server, Handler, Owner
                    ) of
                        ok -> {ok, added};
                        Error -> Error
                    end
            end;
        {win32, _} ->
            case gen_event:add_handler(erl_signal_server, Handler, Owner) of
                ok -> {ok, added};
                Error -> Error
            end
    end.

restore_signal_handler(Handler, swapped_default) ->
    _ = gen_event:swap_handler(
        erl_signal_server,
        {Handler, normal},
        {erl_signal_handler, []}
    ),
    ok;
restore_signal_handler(Handler, added) ->
    _ = gen_event:delete_handler(erl_signal_server, Handler, normal),
    ok.

stop_listener(Listener) when is_pid(Listener) ->
    unlink(Listener),
    Monitor = erlang:monitor(process, Listener),
    exit(Listener, shutdown),
    receive
        {'DOWN', Monitor, process, Listener, _Reason} -> nil
    after 5000 ->
        exit(Listener, kill),
        receive
            {'DOWN', Monitor, process, Listener, _Reason} -> nil
        after 5000 ->
            erlang:demonitor(Monitor, [flush]),
            nil
        end
    end;
stop_listener(_Listener) -> nil.

stop_worker(Worker) when is_pid(Worker) ->
    Monitor = erlang:monitor(process, Worker),
    exit(Worker, kill),
    receive
        {'DOWN', Monitor, process, Worker, _Reason} -> nil
    after 5000 ->
        erlang:demonitor(Monitor, [flush]),
        nil
    end;
stop_worker(_Worker) -> nil.

open_browser(Url) when is_binary(Url) ->
    case local_bootstrap_url(Url) of
        false -> {error, <<"refused a non-loopback bootstrap URL">>};
        true ->
            case browser_command() of
                {error, Reason} -> {error, Reason};
                {ok, Executable, Prefix} ->
                    browser_port(Executable, Prefix ++ [binary_to_list(Url)])
            end
    end;
open_browser(_Url) -> {error, <<"invalid bootstrap URL">>}.

local_bootstrap_url(Url) ->
    lists:any(fun(Prefix) ->
        binary:match(Url, Prefix) =:= {0, byte_size(Prefix)}
    end, [
        <<"http://127.0.0.1:">>,
        <<"http://localhost:">>,
        <<"http://[::1]:">>
    ]).

browser_command() ->
    case os:type() of
        {win32, _} -> find_browser_executable(
            ["rundll32.exe"], ["url.dll,FileProtocolHandler"]
        );
        {unix, darwin} -> find_browser_executable(["open"], []);
        {unix, _} ->
            case find_browser_executable(["xdg-open"], []) of
                {error, _} -> find_browser_executable(["gio"], ["open"]);
                Found -> Found
            end
    end.

find_browser_executable([], _Prefix) ->
    {error, <<"no OS browser launcher was found">>};
find_browser_executable([Name | Rest], Prefix) ->
    case os:find_executable(Name) of
        false -> find_browser_executable(Rest, Prefix);
        Path -> {ok, Path, Prefix}
    end.

browser_port(Executable, Arguments) ->
    try open_port(
        {spawn_executable, Executable},
        [binary, exit_status, stderr_to_stdout, hide,
         {args, Arguments}]
    ) of
        Port ->
            receive
                {Port, {exit_status, 0}} -> {ok, nil};
                {Port, {exit_status, _Status}} ->
                    {error, <<"OS browser launcher exited unsuccessfully">>};
                {Port, {data, _Data}} -> browser_port_drain(Port)
            after 5000 ->
                try port_close(Port) catch _:_ -> ok end,
                {ok, nil}
            end
    catch
        _:_ -> {error, <<"OS browser launcher could not be started">>}
    end.

browser_port_drain(Port) ->
    receive
        {Port, {exit_status, 0}} -> {ok, nil};
        {Port, {exit_status, _Status}} ->
            {error, <<"OS browser launcher exited unsuccessfully">>};
        {Port, {data, _Data}} -> browser_port_drain(Port)
    after 5000 ->
        try port_close(Port) catch _:_ -> ok end,
        {ok, nil}
    end.

init(Owner) when is_pid(Owner) -> {ok, Owner};
init({Owner, _PreviousHandlerState}) when is_pid(Owner) -> {ok, Owner}.

handle_event(sigint, Owner) ->
    Owner ! {beamtrace_shutdown, sigint},
    {ok, Owner};
handle_event(sigterm, Owner) ->
    Owner ! {beamtrace_shutdown, sigterm},
    {ok, Owner};
handle_event({signal, sigint}, Owner) ->
    Owner ! {beamtrace_shutdown, sigint},
    {ok, Owner};
handle_event({signal, sigterm}, Owner) ->
    Owner ! {beamtrace_shutdown, sigterm},
    {ok, Owner};
handle_event(_Event, Owner) -> {ok, Owner}.

handle_call(_Request, Owner) -> {ok, ok, Owner}.
handle_info(_Info, Owner) -> {ok, Owner}.
terminate(_Reason, _Owner) -> ok.
code_change(_OldVersion, Owner, _Extra) -> {ok, Owner}.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
