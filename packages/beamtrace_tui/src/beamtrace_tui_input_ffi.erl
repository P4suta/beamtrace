%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_tui_input_ffi).

-export([install/0]).

%% OTP 27 waits for the full length requested by io:get_chars/2 even after
%% etui enables raw mode. etui 2.0's persistent reader requests 128 bytes, so
%% a single command key never reaches the application on that release.
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
            Pid = spawn(fun() -> reader_loop(Owner) end),
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
