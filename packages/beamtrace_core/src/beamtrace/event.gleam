//// Concise construction of `types.TraceEvent` values.
////
//// A `Builder` carries the context every event repeats — root id, observing
//// process, local instant, and evidence — and one finisher per event kind
//// returns the finished record. The event node is always the process node,
//// so the codec invariant `process.physical.node == event.node` holds by
//// construction. Building never fails; validation stays at the codec and
//// facade boundaries.
////
//// ```gleam
//// let checkout = event.process(node: "shop@localhost", pid: "<0.10.0>")
//// let sent =
////   event.builder(root: "checkout-1", process: checkout)
////   |> event.at(offset_ns: 100, order: 1)
////   |> event.send(
////     id: "send-1",
////     to: types.ProcessRef("shop@localhost", "<0.20.0>"),
////     message: types.TagOnly("charge"),
////     serial: event.serial(previous: 0, current: 1),
////   )
//// ```

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import gleam/option.{None, Some}

/// The shared context of one or more events: root id, observing process,
/// local instant, and evidence. Construct it with `builder`, refine it with
/// `at` and `inferred_by`, and finish it with one function per event kind.
pub opaque type Builder {
  Builder(
    root_id: String,
    process: types.ProcessIdentity,
    local_instant: types.LocalInstant,
    evidence: types.Evidence,
  )
}

/// A physical-only process identity, for events whose logical actor is
/// unknown or irrelevant. Use `actor` when a stable logical identity exists.
pub fn process(node node: String, pid pid: String) -> types.ProcessIdentity {
  types.ProcessIdentity(
    physical: types.ProcessRef(node, pid),
    logical: None,
    evidence: [],
  )
}

/// A process identity with a PID-independent logical actor id and label.
pub fn actor(
  node node: String,
  pid pid: String,
  id id: String,
  label label: String,
) -> types.ProcessIdentity {
  types.ProcessIdentity(
    physical: types.ProcessRef(node, pid),
    logical: Some(types.LogicalActor(id, label)),
    evidence: [],
  )
}

/// An OTP sequence-trace serial with explicit previous and current values.
pub fn serial(
  previous previous: Int,
  current current: Int,
) -> types.SequenceSerial {
  types.SequenceSerial(previous, current)
}

/// Start a builder for events observed by one process under one root.
/// Defaults: the local instant is `LocalInstant(0, 0)` and evidence is
/// `Exact` — refine them with `at` and `inferred_by`.
pub fn builder(
  root root: String,
  process process: types.ProcessIdentity,
) -> Builder {
  Builder(root, process, types.LocalInstant(0, 0), types.Exact)
}

/// Place the next finished event at a node-relative instant. `offset_ns` is
/// relative to the capture-local node origin; `order` breaks local ties.
pub fn at(
  builder: Builder,
  offset_ns offset_ns: Int,
  order order: Int,
) -> Builder {
  Builder(..builder, local_instant: types.LocalInstant(offset_ns, order))
}

/// Mark the next finished event as derived by a stated inference instead of
/// directly observed.
pub fn inferred_by(
  builder: Builder,
  method method: String,
  reason reason: String,
  inputs inputs: List(types.InferenceInput),
) -> Builder {
  Builder(..builder, evidence: types.inferred(method, reason, inputs))
}

/// Finish a `Root` event: the trigger call that started the operation.
pub fn root(
  builder: Builder,
  id id: String,
  trigger trigger: types.Mfa,
  arguments arguments: List(types.TermView),
) -> types.TraceEvent {
  finish(builder, id, types.Root(trigger, arguments))
}

/// Finish a `Send` event to a peer process.
pub fn send(
  builder: Builder,
  id id: String,
  to to: types.ProcessRef,
  message message: types.TermView,
  serial serial: types.SequenceSerial,
) -> types.TraceEvent {
  finish(builder, id, types.Send(to, message, serial))
}

/// Finish a `Received` event from a peer process.
pub fn received(
  builder: Builder,
  id id: String,
  from from: types.ProcessRef,
  message message: types.TermView,
  serial serial: types.SequenceSerial,
) -> types.TraceEvent {
  finish(builder, id, types.Received(from, message, serial))
}

/// Finish a `Spawn` event for a child process and its initial call.
pub fn spawn(
  builder: Builder,
  id id: String,
  child child: types.ProcessRef,
  initial_call initial_call: types.Mfa,
) -> types.TraceEvent {
  finish(builder, id, types.Spawn(child, initial_call))
}

/// Finish an `Exit` event with its reason term.
pub fn exit(
  builder: Builder,
  id id: String,
  reason reason: types.TermView,
) -> types.TraceEvent {
  finish(builder, id, types.Exit(reason))
}

/// Finish a `Register` event for a newly registered name.
pub fn register(
  builder: Builder,
  id id: String,
  name name: String,
) -> types.TraceEvent {
  finish(builder, id, types.Register(name))
}

/// Finish a `Link` event to a peer process.
pub fn link(
  builder: Builder,
  id id: String,
  peer peer: types.ProcessRef,
) -> types.TraceEvent {
  finish(builder, id, types.Link(peer))
}

/// Finish a `Metric` sample event.
pub fn metric(
  builder: Builder,
  id id: String,
  name name: String,
  value value: Float,
) -> types.TraceEvent {
  finish(builder, id, types.Metric(name, value))
}

/// Finish a `SystemSignal` event such as a long garbage collection.
pub fn system_signal(
  builder: Builder,
  id id: String,
  name name: String,
  value value: Int,
) -> types.TraceEvent {
  finish(builder, id, types.SystemSignal(name, value))
}

/// Finish a `Gap` event that keeps dropped events first-class.
pub fn gap(
  builder: Builder,
  id id: String,
  dropped_events dropped_events: Int,
  reason reason: String,
) -> types.TraceEvent {
  finish(builder, id, types.Gap(dropped_events, reason))
}

/// Finish a `Stop` event that records why the observation ended.
pub fn stop(
  builder: Builder,
  id id: String,
  reason reason: String,
) -> types.TraceEvent {
  finish(builder, id, types.Stop(reason))
}

fn finish(
  builder: Builder,
  id: String,
  kind: types.TraceEventKind,
) -> types.TraceEvent {
  types.TraceEvent(
    id: id,
    root_id: builder.root_id,
    node: builder.process.physical.node,
    process: builder.process,
    local_instant: builder.local_instant,
    kind: kind,
    evidence: builder.evidence,
  )
}
