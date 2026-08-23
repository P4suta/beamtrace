// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/team_store
import gleam/int
import gleam/list
import gleam/string

pub type MemoryStore

pub opaque type Store {
  Ephemeral(memory: MemoryStore)
  Durable(database: team_store.Store)
}

pub type Annotation {
  Annotation(
    id: String,
    event_id: String,
    text: String,
    author: String,
    created_at_ms: Int,
  )
}

pub type AnnotationError {
  InvalidEventId
  InvalidText
  StorageError(reason: String)
}

@external(erlang, "beamtrace_annotations_ffi", "new")
fn new_memory() -> MemoryStore

pub fn new() -> Store {
  Ephemeral(new_memory())
}

pub fn persistent(database: team_store.Store) -> Store {
  Durable(database)
}

pub fn append(
  store: Store,
  event_id event_id: String,
  text text: String,
  author author: String,
  created_at_ms created_at_ms: Int,
) -> Result(Annotation, AnnotationError) {
  let event_id = string.trim(event_id)
  let text = string.trim(text)
  case
    event_id == "" || string.length(event_id) > 256,
    text == "" || string.length(text) > 4096
  {
    True, _ -> Error(InvalidEventId)
    _, True -> Error(InvalidText)
    False, False ->
      append_valid(store, event_id, text, author, int.max(0, created_at_ms))
  }
}

@external(erlang, "beamtrace_annotations_ffi", "append")
fn append_memory(
  store: MemoryStore,
  event_id: String,
  text: String,
  author: String,
  created_at_ms: Int,
) -> Annotation

fn append_valid(
  store: Store,
  event_id: String,
  text: String,
  author: String,
  created_at_ms: Int,
) -> Result(Annotation, AnnotationError) {
  case store {
    Ephemeral(memory) ->
      Ok(append_memory(memory, event_id, text, author, created_at_ms))
    Durable(database) ->
      case
        team_store.append_annotation(
          database,
          event_id,
          text,
          author,
          created_at_ms,
        )
      {
        Ok(row) -> Ok(from_row(row))
        Error(reason) -> Error(StorageError(reason))
      }
  }
}

@external(erlang, "beamtrace_annotations_ffi", "list")
fn list_memory(store: MemoryStore) -> List(Annotation)

pub fn list_result(store: Store) -> Result(List(Annotation), String) {
  case store {
    Ephemeral(memory) -> Ok(list_memory(memory))
    Durable(database) ->
      case team_store.annotations(database) {
        Ok(rows) -> Ok(rows |> list.map(from_row))
        Error(reason) -> Error(reason)
      }
  }
}

pub fn list(store: Store) -> List(Annotation) {
  case list_result(store) {
    Ok(annotations) -> annotations
    Error(_) -> []
  }
}

@external(erlang, "beamtrace_annotations_ffi", "close")
fn close_memory(store: MemoryStore) -> Nil

pub fn close(store: Store) -> Nil {
  case store {
    Ephemeral(memory) -> close_memory(memory)
    Durable(_) -> Nil
  }
}

fn from_row(row: team_store.AnnotationRow) -> Annotation {
  Annotation(row.id, row.event_id, row.text, row.author, row.created_at_ms)
}
