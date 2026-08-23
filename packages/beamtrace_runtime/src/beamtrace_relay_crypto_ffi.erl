%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_relay_crypto_ffi).

-export([new_identity/0, sign/2, verify/3]).

new_identity() ->
    {PublicKey, PrivateKey} = crypto:generate_key(eddsa, ed25519),
    {identity, PublicKey, PrivateKey}.

sign({identity, _PublicKey, PrivateKey}, Payload)
        when is_binary(PrivateKey), is_binary(Payload) ->
    crypto:sign(eddsa, none, Payload, [PrivateKey, ed25519]).

verify(PublicKey, Payload, Signature)
        when is_binary(PublicKey), is_binary(Payload), is_binary(Signature) ->
    try crypto:verify(eddsa, none, Payload, Signature, [PublicKey, ed25519])
    catch
        _:_ -> false
    end.
