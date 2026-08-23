// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub fn workspace(model: workspace.Model) -> Element(workspace.Msg) {
  html.main(
    [
      attribute.class("workspace"),
      attribute.attribute("data-mode", mode_slug(model.mode)),
    ],
    [
      workspace_header(model),
      html.div([attribute.class("workspace-grid")], [
        session_navigator(),
        causal_workspace(model),
        inspector(model),
      ]),
      minimap(model),
      palette(model),
    ],
  )
}

fn workspace_header(model: workspace.Model) -> Element(workspace.Msg) {
  html.header([attribute.class("topbar")], [
    html.div([attribute.class("brand")], [
      html.span([attribute.class("brand-mark"), attribute.aria_hidden(True)], [
        html.text("AG"),
      ]),
      html.div([], [
        html.h1([], [html.text("BeamTrace")]),
        html.p([], [html.text("BEAM causal workbench")]),
      ]),
    ]),
    html.nav([attribute.aria_label("Workspace mode")], [
      mode_button(model.mode, workspace.Capture, "Capture", "1"),
      mode_button(model.mode, workspace.Live, "Live", "2"),
      mode_button(model.mode, workspace.Compare, "Compare", "3"),
    ]),
    html.div([attribute.class("topbar-actions")], [
      html.label([attribute.class("search")], [
        html.span([attribute.class("sr-only")], [html.text("Search events")]),
        html.input([
          attribute.type_("search"),
          attribute.value(model.query),
          attribute.placeholder("Search actor, message, MFA…"),
          attribute.aria_label("Search events"),
          attribute.aria_keyshortcuts("/"),
          event.on_input(workspace.UserChangedQuery),
        ]),
      ]),
      html.button(
        [
          attribute.class("quiet-button"),
          attribute.aria_keyshortcuts("Control+K"),
          event.on_click(workspace.UserOpenedPalette),
        ],
        [html.text("Commands  ⌘K")],
      ),
    ]),
  ])
}

fn mode_button(
  current: workspace.Mode,
  mode: workspace.Mode,
  label: String,
  shortcut: String,
) -> Element(workspace.Msg) {
  html.button(
    [
      attribute.class(case current == mode {
        True -> "mode-button active"
        False -> "mode-button"
      }),
      attribute.aria_pressed(case current == mode {
        True -> "true"
        False -> "false"
      }),
      attribute.aria_keyshortcuts(shortcut),
      event.on_click(workspace.UserSelectedMode(mode)),
    ],
    [html.span([attribute.class("mode-dot")], []), html.text(label)],
  )
}

fn session_navigator() -> Element(workspace.Msg) {
  html.nav(
    [
      attribute.class("navigator panel"),
      attribute.aria_label("Session navigator"),
    ],
    [
      panel_heading("Nodes & sessions", "01"),
      html.section([], [
        html.h2([], [html.text("Connected nodes")]),
        html.button([attribute.class("node-card selected")], [
          html.span([attribute.class("status-dot healthy")], []),
          html.span([], [
            html.strong([], [html.text("checkout@local")]),
            html.span([], [html.text("OTP 29 · connected")]),
          ]),
        ]),
        html.button([attribute.class("node-card")], [
          html.span([attribute.class("status-dot warning")], []),
          html.span([], [
            html.strong([], [html.text("payments@local")]),
            html.span([], [html.text("clock ±3.2 ms")]),
          ]),
        ]),
      ]),
      html.section([], [
        html.h2([], [html.text("Capture sessions")]),
        html.ol([attribute.class("session-list")], [
          session_item("#1042", "checkout.handle/1", "Complete", True),
          session_item("#1041", "checkout.handle/1", "Truncated", False),
          session_item("#1040", "worker.run/2", "Complete", False),
        ]),
      ]),
    ],
  )
}

fn session_item(
  id: String,
  trigger: String,
  status: String,
  active: Bool,
) -> Element(workspace.Msg) {
  html.li([], [
    html.button(
      [
        attribute.class(case active {
          True -> "session active"
          False -> "session"
        }),
      ],
      [
        html.span([], [html.strong([], [html.text(id)]), html.text(trigger)]),
        html.span([attribute.class("session-status")], [html.text(status)]),
      ],
    ),
  ])
}

fn causal_workspace(model: workspace.Model) -> Element(workspace.Msg) {
  let visible = workspace.visible_events(model)
  let shown_count = list.length(visible)
  let total_count = model.total_events

  html.section(
    [attribute.class("causal panel"), attribute.aria_label("Causal timeline")],
    [
      html.div([attribute.class("panel-toolbar")], [
        html.div([], [
          html.p([attribute.class("eyebrow")], [
            html.text(mode_slug(model.mode)),
          ]),
          html.h2([], [html.text(mode_title(model.mode))]),
        ]),
        html.div([attribute.class("toolbar-actions")], [
          html.button(
            [
              attribute.class("quiet-button"),
              attribute.aria_pressed(case model.show_internal {
                True -> "true"
                False -> "false"
              }),
              event.on_click(workspace.UserToggledInternalNoise),
            ],
            [
              html.text(case model.show_internal {
                True -> "Fold OTP noise"
                False -> "Expand OTP noise"
              }),
            ],
          ),
          html.span(
            [attribute.class("window-count"), attribute.aria_live("polite")],
            [
              html.text(case model.loading, model.load_error {
                True, _ -> "Loading event window…"
                False, Some(reason) -> "Page unavailable · " <> reason
                False, None ->
                  int.to_string(shown_count)
                  <> " visible / "
                  <> int.to_string(total_count)
                  <> " total"
              }),
            ],
          ),
        ]),
      ]),
      html.div([attribute.class("canvas-frame")], [
        html.canvas([
          attribute.id("causal-canvas"),
          attribute.attribute("width", "1600"),
          attribute.attribute("height", "620"),
          attribute.aria_hidden(True),
        ]),
        html.div([attribute.class("lane-labels"), attribute.aria_hidden(True)], [
          html.span([], [html.text("checkout")]),
          html.span([], [html.text("cart_server")]),
          html.span([], [html.text("payment_worker")]),
        ]),
      ]),
      event_table(visible),
    ],
  )
}

fn event_table(rows: List(workspace.EventRow)) -> Element(workspace.Msg) {
  html.div([attribute.class("event-table-wrap")], [
    html.table([attribute.aria_label("Accessible causal event table")], [
      html.thead([], [
        html.tr([], [
          html.th([], [html.text("Event")]),
          html.th([], [html.text("Actor")]),
          html.th([], [html.text("Kind")]),
          html.th([], [html.text("Time")]),
          html.th([], [html.text("Evidence")]),
        ]),
      ]),
      html.tbody([], list.map(rows, event_row)),
    ]),
  ])
}

fn event_row(row: workspace.EventRow) -> Element(workspace.Msg) {
  html.tr(
    [
      attribute.class(case row.anomalous {
        True -> "anomalous"
        False -> ""
      }),
      event.on_click(workspace.UserSelectedEvent(row.id)),
    ],
    [
      html.td([], [
        html.button([attribute.class("event-link")], [html.text(row.id)]),
      ]),
      html.td([], [html.text(row.actor)]),
      html.td([], [
        html.span([attribute.class("kind-pill")], [html.text(row.kind)]),
      ]),
      html.td([], [html.text(int.to_string(row.timestamp_ns) <> " ns")]),
      html.td([], [html.text(evidence_label(row.evidence))]),
    ],
  )
}

fn inspector(model: workspace.Model) -> Element(workspace.Msg) {
  html.aside(
    [
      attribute.class("inspector panel"),
      attribute.aria_label("Event inspector"),
    ],
    [
      panel_heading("Event inspector", "03"),
      case workspace.selected_event(model) {
        None ->
          html.div([attribute.class("empty-state")], [
            html.p([], [html.text("Select an event to inspect exact evidence.")]),
          ])
        Some(row) -> inspector_event(model, row)
      },
    ],
  )
}

fn inspector_event(
  model: workspace.Model,
  row: workspace.EventRow,
) -> Element(workspace.Msg) {
  let bookmarked = list.contains(model.bookmarks, row.id)
  html.div([attribute.class("inspector-content")], [
    html.div([attribute.class("inspector-title")], [
      html.div([], [
        html.p([attribute.class("eyebrow")], [html.text(row.kind)]),
        html.h2([], [html.text(row.actor)]),
      ]),
      html.button(
        [
          attribute.class("bookmark-button"),
          attribute.aria_pressed(case bookmarked {
            True -> "true"
            False -> "false"
          }),
          event.on_click(workspace.UserToggledBookmark(row.id)),
        ],
        [
          html.text(case bookmarked {
            True -> "★"
            False -> "☆"
          }),
        ],
      ),
    ]),
    definition("Event ID", row.id),
    definition("Evidence", evidence_label(row.evidence)),
    definition("Duration", int.to_string(row.duration_ns) <> " ns"),
    definition("Boundary", "None observed"),
    html.a(
      [
        attribute.class("source-link"),
        attribute.attribute("href", "vscode://file/src/checkout.gleam:42"),
      ],
      [html.text("Open source · checkout.gleam:42")],
    ),
    html.label([attribute.class("annotation")], [
      html.span([], [html.text("Annotation")]),
      html.textarea(
        [
          attribute.placeholder("Record what this event explains…"),
          attribute.value(model.annotation),
          event.on_input(workspace.UserChangedAnnotation),
        ],
        model.annotation,
      ),
    ]),
  ])
}

fn definition(label: String, value: String) -> Element(workspace.Msg) {
  html.div([attribute.class("definition")], [
    html.span([], [html.text(label)]),
    html.strong([], [html.text(value)]),
  ])
}

fn minimap(model: workspace.Model) -> Element(workspace.Msg) {
  let previous = int.max(model.viewport_start - model.viewport_size, 0)
  let last_start = int.max(model.total_events - model.viewport_size, 0)
  let next = int.min(model.viewport_start + model.viewport_size, last_start)
  let shown_end =
    int.min(model.viewport_start + model.viewport_size, model.total_events)
  html.footer(
    [attribute.class("minimap"), attribute.aria_label("Time minimap")],
    [
      html.button(
        [
          attribute.class("quiet-button"),
          attribute.disabled(model.viewport_start == 0 || model.loading),
          event.on_click(workspace.ViewportChanged(
            previous,
            model.viewport_size,
          )),
        ],
        [html.text("Previous")],
      ),
      html.div([attribute.class("minimap-track")], [
        html.div(
          [
            attribute.class("minimap-window"),
            attribute.attribute(
              "data-start",
              int.to_string(model.viewport_start),
            ),
          ],
          [],
        ),
      ]),
      html.span([], [
        html.text(
          int.to_string(model.viewport_start + 1)
          <> "–"
          <> int.to_string(shown_end)
          <> " / "
          <> int.to_string(model.total_events),
        ),
      ]),
      html.button(
        [
          attribute.class("quiet-button"),
          attribute.disabled(shown_end >= model.total_events || model.loading),
          event.on_click(workspace.ViewportChanged(next, model.viewport_size)),
        ],
        [html.text("Next")],
      ),
      html.span([attribute.class("zoom-label")], [
        html.text("Zoom " <> zoom_label(model.zoom)),
      ]),
    ],
  )
}

fn palette(model: workspace.Model) -> Element(workspace.Msg) {
  case model.palette_open {
    False -> html.div([], [])
    True ->
      html.dialog(
        [
          attribute.class("command-palette"),
          attribute.attribute("open", ""),
          attribute.aria_modal(True),
          attribute.aria_label("Command palette"),
        ],
        [
          html.div([attribute.class("palette-heading")], [
            html.strong([], [html.text("Command palette")]),
            html.button([event.on_click(workspace.UserClosedPalette)], [
              html.text("Close"),
            ]),
          ]),
          html.button(
            [event.on_click(workspace.UserSelectedMode(workspace.Capture))],
            [
              html.text("Arm capture trigger"),
            ],
          ),
          html.button(
            [event.on_click(workspace.UserSelectedMode(workspace.Live))],
            [
              html.text("Open live anomalies"),
            ],
          ),
          html.button(
            [event.on_click(workspace.UserSelectedMode(workspace.Compare))],
            [
              html.text("Compare saved traces"),
            ],
          ),
        ],
      )
  }
}

fn panel_heading(title: String, index: String) -> Element(workspace.Msg) {
  html.div([attribute.class("panel-heading")], [
    html.span([], [html.text(index)]),
    html.strong([], [html.text(title)]),
  ])
}

fn mode_slug(mode: workspace.Mode) -> String {
  case mode {
    workspace.Capture -> "capture"
    workspace.Live -> "live"
    workspace.Compare -> "compare"
  }
}

fn mode_title(mode: workspace.Mode) -> String {
  case mode {
    workspace.Capture -> "Exact causal sequence"
    workspace.Live -> "Runtime signals"
    workspace.Compare -> "Trace alignment"
  }
}

fn evidence_label(evidence: workspace.Evidence) -> String {
  case evidence {
    workspace.Exact -> "Exact"
    workspace.Inferred(reason, confidence) ->
      "Inferred " <> zoom_label(confidence) <> " · " <> reason
  }
}

fn zoom_label(value: Float) -> String {
  case value {
    0.25 -> "25%"
    0.5 -> "50%"
    1.0 -> "100%"
    2.0 -> "200%"
    4.0 -> "400%"
    _ -> "custom"
  }
}
