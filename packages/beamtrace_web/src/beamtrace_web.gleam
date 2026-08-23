// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/canvas
import beamtrace_web/page_loader
import beamtrace_web/view
import beamtrace_web/workspace
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
  let next = workspace.update(model, message)
  case workspace.needs_page(next) {
    False -> #(next, draw_effect(next))
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
        ]),
      )
    }
  }
}

fn startup_effect(model: workspace.Model) -> Effect(workspace.Msg) {
  effect.batch([
    draw_effect(model),
    page_loader.load(0, 200, workspace.remote_query(model)),
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
