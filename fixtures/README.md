# Capture fixtures

The Gleam, Elixir, and Erlang fixtures intentionally implement the same causal shape:

1. a public `operation` function performs an OTP call to a worker;
2. the worker calls a leaf process and relays its reply;
3. a cast mutates private worker state;
4. an intentional crash is followed by a one-for-one supervisor restart.

These applications contain no BeamTrace dependency or instrumentation. They are targets for attach/capture compatibility tests.
