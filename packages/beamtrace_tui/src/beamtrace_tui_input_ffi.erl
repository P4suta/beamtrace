%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_tui_input_ffi).

-export([install/0]).

%% OTP 27 waits for the full length requested by io:get_chars/2 even after
%% etui enables raw mode. etui 2.0's persistent reader requests 128 bytes, so
%% a single command key never reaches the application on that release. The
%% first read must also start after etui has entered raw mode; a read issued in
%% cooked mode keeps waiting for a line even if the terminal changes later.
%%
%% etui deliberately discovers its reader by this registered name. Installing
%% a one-byte reader first preserves etui's parser and queue while restoring
%% single-key input on OTP 27. Its normal cleanup owns and stops this process.
install() ->
    case erlang:system_info(otp_release) of
        "27" ++ _ -> install_reader(self());
        _ -> nil
    end.

install_reader(Owner) ->
    case erlang:whereis(etui_kbd_reader) of
        undefined ->
            Pid = spawn(fun() -> wait_for_raw_mode(Owner) end),
            try erlang:register(etui_kbd_reader, Pid) of
                true -> nil
            catch
                error:badarg ->
                    exit(Pid, kill),
                    nil
            end;
        _ ->
            nil
    end.

wait_for_raw_mode(Owner) ->
    Monitor = erlang:monitor(process, Owner),
    wait_for_raw_mode(Owner, Monitor).

wait_for_raw_mode(Owner, Monitor) ->
    receive
        {'DOWN', Monitor, process, Owner, _Reason} ->
            nil
    after 1 ->
        case raw_mode_active() of
            true ->
                erlang:demonitor(Monitor, [flush]),
                reader_loop(Owner);
            false ->
                wait_for_raw_mode(Owner, Monitor)
        end
    end.

raw_mode_active() ->
    case ets:whereis(etui_tty_state) of
        undefined -> false;
        _ -> etui_tty_state:is_raw_mode()
    end.

reader_loop(Owner) ->
    case io:get_chars("", 1) of
        eof ->
            Owner ! {etui_input, <<>>};
        Raw ->
            Owner ! {etui_input, to_binary(Raw)},
            reader_loop(Owner)
    end.

to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Encoded when is_binary(Encoded) -> Encoded;
        _ -> iolist_to_binary(List)
    end;
to_binary(_) ->
    <<>>.
