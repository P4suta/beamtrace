//// Resolve physical processes to evidence-backed logical actor identities.
////
//// Resolution never treats a PID as stable across runs and never fabricates
//// identity evidence. Operations are linear in the small evidence lists and
//// have no runtime-specific effects, so results match on both Gleam targets.

import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Resolve a physical PID into a stable logical actor signature. The complete
/// evidence list is retained so callers can explain or reject the grouping.
pub fn resolve(
  physical: types.ProcessRef,
  metadata: types.ProcessMetadata,
) -> types.ProcessIdentity {
  let evidence = evidence(metadata)
  let logical = case logical_label(metadata) {
    None -> None
    Some(label) -> {
      let ancestry = case metadata.ancestors {
        [] -> ""
        values -> string.join(values, "/") <> "/"
      }
      Some(types.LogicalActor(ancestry <> label, label))
    }
  }

  types.ProcessIdentity(
    physical: physical,
    logical: logical,
    evidence: evidence,
  )
}

/// Return true only when both identities have the same evidence-derived
/// logical identifier. Missing logical identity never falls back to PID.
/// Comparison is O(identifier length) and cannot fail.
pub fn same_logical_actor(
  left: types.ProcessIdentity,
  right: types.ProcessIdentity,
) -> Bool {
  case left.logical, right.logical {
    Some(left), Some(right) -> left.id == right.id
    _, _ -> False
  }
}

fn logical_label(metadata: types.ProcessMetadata) -> Option(String) {
  case
    metadata.process_label,
    metadata.registered_name,
    metadata.supervisor_child_id,
    metadata.initial_call
  {
    Some(value), _, _, _ -> Some(value)
    _, Some(value), _, _ -> Some(value)
    _, _, Some(value), _ -> Some(value)
    _, _, _, Some(types.Mfa(module, function, arity)) ->
      Some(module <> ":" <> function <> "/" <> int.to_string(arity))
    _, _, _, _ -> None
  }
}

fn evidence(metadata: types.ProcessMetadata) -> List(types.IdentityEvidence) {
  let registered = case metadata.registered_name {
    Some(value) -> [types.RegisteredName(value)]
    None -> []
  }
  let label = case metadata.process_label {
    Some(value) -> [types.ProcessLabel(value)]
    None -> []
  }
  let initial = case metadata.initial_call {
    Some(value) -> [types.InitialCall(value)]
    None -> []
  }
  let ancestors = list.map(metadata.ancestors, types.Ancestor)
  let child = case metadata.supervisor_child_id {
    Some(value) -> [types.SupervisorChildId(value)]
    None -> []
  }

  registered
  |> list.append(label)
  |> list.append(initial)
  |> list.append(ancestors)
  |> list.append(child)
}
