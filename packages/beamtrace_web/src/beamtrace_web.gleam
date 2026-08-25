// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/canvas
import beamtrace_web/capture_control
import beamtrace_web/compare_control
import beamtrace_web/live_control
import beamtrace_web/page_loader
import beamtrace_web/team_control
import beamtrace_web/view
import beamtrace_web/workspace
import gleam/option.{None, Some}
import lustre
import lustre/effect.{type Effect}

pub fn main() {
  let app = lustre.application(init, update, view.workspace)
  let assert Ok(_) = lustre.start(app, onto: "#app", with: Nil)
  Nil
}

fn init(_flags) -> #(workspace.Model, Effect(workspace.Msg)) {
  let model = workspace.init_remote()
  #(model, startup_effect(model))
}

fn update(
  model: workspace.Model,
  message: workspace.Msg,
) -> #(workspace.Model, Effect(workspace.Msg)) {
  case message {
    workspace.UserSelectedMode(workspace.Live) ->
      finish_update(workspace.update(model, message), [live_control.load()])
    workspace.UserSelectedMode(workspace.Team) -> {
      let next = workspace.update(model, message)
      case next.team_traces {
        [] -> finish_update(next, [team_control.load_traces("")])
        _ -> finish_update(next, [])
      }
    }
    workspace.UserChangedTrigger(query) ->
      finish_update(workspace.update(model, message), [
        capture_control.search_mfas(query),
      ])
    workspace.UserRequestedArm -> {
      let next = workspace.update(model, message)
      case next.capture_phase {
        workspace.Arming ->
          finish_update(next, [
            capture_control.arm(
              next.trigger_input,
              next.capture_where,
              next.capture_preset,
              next.capture_max_roots,
            ),
          ])
        _ -> finish_update(next, [])
      }
    }
    workspace.CaptureArmAccepted ->
      finish_update(workspace.update(model, message), [
        capture_control.poll_after(150),
      ])
    workspace.PollCaptureStatus ->
      finish_update(workspace.update(model, message), [capture_control.status()])
    workspace.CaptureStatusLoaded(phase) -> {
      let next = workspace.update(model, message)
      case phase {
        workspace.Armed | workspace.Arming | workspace.Cancelling ->
          finish_update(next, [capture_control.poll_after(150)])
        _ -> finish_update(next, [])
      }
    }
    workspace.UserRequestedCancel ->
      finish_update(workspace.update(model, message), [capture_control.cancel()])
    workspace.UserRequestedSave ->
      finish_update(workspace.update(model, message), [
        capture_control.save(model.save_path),
      ])
    workspace.UserRequestedCompare -> {
      let next = workspace.update(model, message)
      case next.compare_loading {
        True ->
          finish_update(next, [
            compare_control.run(workspace.compare_paths(next)),
          ])
        False -> finish_update(next, [])
      }
    }
    workspace.PollLive -> {
      let next = workspace.update(model, message)
      case next.mode {
        workspace.Live -> finish_update(next, [live_control.load()])
        _ -> finish_update(next, [])
      }
    }
    workspace.LiveLoaded(_) -> {
      let next = workspace.update(model, message)
      case next.mode {
        workspace.Live -> finish_update(next, [live_control.poll_after(1000)])
        _ -> finish_update(next, [])
      }
    }
    workspace.LiveLoadFailed(_) -> {
      let next = workspace.update(model, message)
      case next.mode {
        workspace.Live -> finish_update(next, [live_control.poll_after(2000)])
        _ -> finish_update(next, [])
      }
    }
    workspace.UserRequestedTeamTraces ->
      finish_update(workspace.update(model, message), [
        team_control.load_traces(""),
      ])
    workspace.UserRequestedMoreTeamTraces -> {
      let next = workspace.update(model, message)
      case model.team_next_cursor {
        Some(cursor) -> finish_update(next, [team_control.load_traces(cursor)])
        None -> finish_update(next, [])
      }
    }
    workspace.UserSelectedTeamTrace(trace_id) -> {
      let next = workspace.update(model, message)
      case workspace.selected_team_trace(next) {
        Some(trace) if !trace.locked ->
          finish_update(next, [team_control.load_events(trace_id, "")])
        _ -> finish_update(next, [])
      }
    }
    workspace.UserRequestedMoreTeamEvents -> {
      let next = workspace.update(model, message)
      case model.selected_trace_id, model.team_events_next_cursor {
        Some(trace_id), Some(cursor) ->
          finish_update(next, [team_control.load_events(trace_id, cursor)])
        _, _ -> finish_update(next, [])
      }
    }
    workspace.UserRequestedTraceHold(trace_id, enabled) ->
      finish_update(workspace.update(model, message), [
        team_control.set_hold(trace_id, enabled),
      ])
    _ -> finish_update(workspace.update(model, message), [])
  }
}

fn finish_update(
  next: workspace.Model,
  extra_effects: List(Effect(workspace.Msg)),
) -> #(workspace.Model, Effect(workspace.Msg)) {
  case workspace.needs_page(next) {
    False -> #(next, effect.batch([draw_effect(next), ..extra_effects]))
    True -> {
      let loading = workspace.begin_loading(next)
      #(
        loading,
        effect.batch([
          draw_effect(loading),
          page_loader.load(
            loading.viewport_start,
            page_limit(loading),
            workspace.remote_query(loading),
          ),
          ..extra_effects
        ]),
      )
    }
  }
}

fn startup_effect(model: workspace.Model) -> Effect(workspace.Msg) {
  effect.batch([
    draw_effect(model),
    page_loader.load(0, 200, workspace.remote_query(model)),
    capture_control.status(),
    capture_control.install_cleanup(),
    effect.from(fn(dispatch) {
      canvas.install_shortcuts(fn(key) {
        dispatch(workspace.UserPressedKey(key))
      })
    }),
  ])
}

fn page_limit(model: workspace.Model) -> Int {
  let requested = model.viewport_size * 2
  case requested < 200, requested > 1000 {
    True, _ -> 200
    _, True -> 1000
    False, False -> requested
  }
}

fn draw_effect(model: workspace.Model) -> Effect(workspace.Msg) {
  let source = canvas.payload(model)
  let zoom = model.zoom
  effect.before_paint(fn(_dispatch, root) { canvas.draw(root, source, zoom) })
}
