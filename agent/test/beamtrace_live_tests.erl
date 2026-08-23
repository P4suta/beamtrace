%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_live_tests).
-include_lib("eunit/include/eunit.hrl").

bounded_remote_sampling_test_() ->
    {timeout, 30, fun bounded_remote_sampling/0}.

bounded_remote_sampling() ->
    Cookie = atom_to_binary(erlang:get_cookie(), utf8),
    {ok, Peer, Node} = beamtrace_test_peer:start("ag_live_", Cookie),
    try
        {ok, {Samples, NextOffset}} = beamtrace_capture_ffi:sample_remote(
            atom_to_binary(Node, utf8),
            Cookie,
            0,
            7
        ),
        ?assert(length(Samples) =< 7),
        ?assert(is_integer(NextOffset)),
        ?assert(lists:all(fun(Sample) ->
            is_tuple(Sample)
                andalso tuple_size(Sample) =:= 16
                andalso element(1, Sample) =:= raw_process_sample
                andalso is_list(element(15, Sample))
                andalso is_list(element(16, Sample))
        end, Samples)),
        ?assertEqual(nomatch, binary:match(term_to_binary(Samples), <<"messages">>)),
        Release = erpc:call(Node, erlang, system_info, [otp_release]),
        ?assert(is_list(Release) orelse is_binary(Release))
    after
        try peer:stop(Peer)
        catch
            exit:noproc -> ok
        end
    end.
