// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/appearance
import beamtrace_web/time_format
import beamtrace_web/workspace
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

type ComparedItem {
  ComparedItem(path: String, item: workspace.CompareItem)
}

pub fn workspace(model: workspace.Model) -> Element(workspace.Msg) {
  html.main(
    [
      attribute.class("workspace"),
      attribute.attribute("data-mode", mode_slug(model.mode)),
    ],
    [
      workspace_header(model),
      capture_controls(model),
      mobile_mode_navigation(model),
      html.div([attribute.class("workspace-grid")], [
        session_navigator(model),
        causal_workspace(model),
        inspector(model),
      ]),
      mobile_drawers(model),
      minimap(model),
      palette(model),
    ],
  )
}

fn capture_controls(model: workspace.Model) -> Element(workspace.Msg) {
  let sealed_landing =
    capture_ready(model.capture_phase) && !model.capture_form_open
  case model.mode {
    workspace.Capture if sealed_landing -> archive_overview(model)
    workspace.Capture ->
      html.section(
        [
          attribute.class("capture-controls"),
          attribute.aria_label("Capture controls"),
        ],
        [
          html.label([], [
            html.span([], [html.text("MFA trigger")]),
            html.input([
              attribute.type_("text"),
              attribute.aria_label("MFA trigger"),
              attribute.placeholder("module:function/arity"),
              attribute.attribute("list", "mfa-candidates"),
              attribute.value(model.trigger_input),
              event.on_input(workspace.UserChangedTrigger),
            ]),
            html.datalist(
              [attribute.id("mfa-candidates")],
              list.map(model.mfa_suggestions, fn(candidate) {
                html.option([attribute.value(candidate)], candidate)
              }),
            ),
          ]),
          html.button(
            [
              attribute.disabled(capture_arm_disabled(model.capture_phase)),
              event.on_click(workspace.UserRequestedArm),
            ],
            [html.text("Arm capture")],
          ),
          html.button(
            [
              attribute.disabled(!capture_busy(model.capture_phase)),
              event.on_click(workspace.UserRequestedCancel),
            ],
            [html.text("Cancel capture")],
          ),
          capture_advanced(model),
          capture_save_controls(model),
          case capture_ready(model.capture_phase) {
            True ->
              html.button(
                [
                  attribute.class("quiet-button"),
                  event.on_click(workspace.UserClosedCaptureForm),
                ],
                [html.text("Back to result")],
              )
            False -> html.div([], [])
          },
          html.output(
            [
              attribute.class("capture-status"),
              attribute.aria_live("polite"),
            ],
            [
              html.text(capture_phase_label(model.capture_phase)),
              html.span([], [html.text(capture_recovery(model))]),
            ],
          ),
        ],
      )
    workspace.Compare -> compare_controls(model)
    _ -> html.div([], [])
  }
}

/// Landing for a sealed archive: what was observed, whether it verified,
/// and the two actions that still apply (save it, start a new capture).
fn archive_overview(model: workspace.Model) -> Element(workspace.Msg) {
  let #(count, outcome) = case model.capture_phase {
    workspace.Ready(count, outcome) -> #(count, outcome)
    _ -> #(model.total_events, "")
  }
  html.section(
    [
      attribute.class("capture-controls archive-overview"),
      attribute.aria_label("Sealed archive"),
    ],
    [
      html.div([], [
        html.h2([], [html.text("Sealed archive")]),
        html.p([], [
          html.text(
            int.to_string(count)
            <> " events · "
            <> outcome
            <> ". Choose a save path to retain this archive.",
          ),
        ]),
      ]),
      capture_save_controls(model),
      html.button(
        [
          attribute.class("quiet-button"),
          event.on_click(workspace.UserOpenedCaptureForm),
        ],
        [html.text("New capture")],
      ),
    ],
  )
}

fn capture_advanced(model: workspace.Model) -> Element(workspace.Msg) {
  html.details([attribute.class("capture-advanced")], [
    html.summary([], [html.text("Advanced")]),
    html.div([attribute.class("capture-advanced-grid")], [
      html.label([], [
        html.span([], [html.text("AQL condition")]),
        html.input([
          attribute.type_("text"),
          attribute.aria_label("AQL condition"),
          attribute.placeholder("arg.0.tag == order"),
          attribute.value(model.capture_where),
          event.on_input(workspace.UserChangedCaptureWhere),
        ]),
      ]),
      html.label([], [
        html.span([], [html.text("Framework preset")]),
        html.select(
          [
            attribute.aria_label("Framework preset"),
            attribute.value(model.capture_preset),
            event.on_input(workspace.UserChangedCapturePreset),
          ],
          [
            preset_option("generic", "Generic"),
            preset_option("gleam-actor", "Gleam actor"),
            preset_option("wisp-mist", "Wisp / Mist"),
            preset_option("gen-server", "GenServer"),
            preset_option("phoenix", "Phoenix"),
            preset_option("erlang-supervisor", "Erlang supervisor"),
          ],
        ),
      ]),
      html.label([], [
        html.span([], [html.text("Max roots")]),
        html.input([
          attribute.type_("number"),
          attribute.aria_label("Max roots"),
          attribute.attribute("min", "1"),
          attribute.attribute("max", "1000"),
          attribute.value(model.capture_max_roots),
          event.on_input(workspace.UserChangedMaxRoots),
        ]),
      ]),
    ]),
  ])
}

fn capture_save_controls(model: workspace.Model) -> Element(workspace.Msg) {
  case capture_ready(model.capture_phase) {
    False -> html.div([attribute.class("capture-save pending")], [])
    True ->
      html.div([attribute.class("capture-save")], [
        html.label([], [
          html.span([], [html.text("Save path")]),
          html.input([
            attribute.type_("text"),
            attribute.aria_label("Save path"),
            attribute.value(model.save_path),
            event.on_input(workspace.UserChangedSavePath),
          ]),
        ]),
        html.button([event.on_click(workspace.UserRequestedSave)], [
          html.text("Save capture"),
        ]),
      ])
  }
}

fn capture_recovery(model: workspace.Model) -> String {
  case model.capture_phase {
    workspace.Unavailable ->
      "Attach a node with beamtrace attach, then search for an MFA."
    workspace.Idle if model.capture_notice == "" ->
      "Search for the operation's MFA, then arm one bounded capture."
    workspace.Failed("system_tracer_occupied") ->
      "Another tracer owns the VM. Stop that tracer or switch to Live sampling."
    workspace.Failed("trigger_required") ->
      "Enter Module:function/arity or choose an MFA search result."
    workspace.Failed(_) ->
      model.capture_notice <> " Check the target connection, then arm again."
    workspace.Ready(_, outcome) if model.capture_notice == "" ->
      case string.contains(outcome, "integrity issues present") {
        True ->
          outcome
          <> ". Validate the archive and retry capture after correcting the named node or delivery problem."
        False -> outcome <> ". Choose a save path to retain this archive."
      }
    _ -> model.capture_notice
  }
}

fn compare_controls(model: workspace.Model) -> Element(workspace.Msg) {
  html.section(
    [
      attribute.class("capture-controls compare-controls"),
      attribute.aria_label("Compare controls"),
    ],
    [
      html.label([], [
        html.span([], [html.text("Trace paths · baseline first")]),
        html.textarea(
          [
            attribute.aria_label("Trace paths"),
            attribute.placeholder(
              "baseline.beamtrace\ncandidate.beamtrace\noptional-third.beamtrace",
            ),
            attribute.value(model.compare_paths_input),
            event.on_input(workspace.UserChangedComparePaths),
          ],
          model.compare_paths_input,
        ),
      ]),
      html.button(
        [
          attribute.disabled(model.compare_loading),
          event.on_click(workspace.UserRequestedCompare),
        ],
        [html.text("Run comparison")],
      ),
      html.output(
        [attribute.class("capture-status"), attribute.aria_live("polite")],
        [
          html.text(case model.compare_loading {
            True -> "Comparing traces"
            False ->
              case model.compare_report {
                Some(report) ->
                  "Compared " <> int.to_string(report.run_count) <> " runs"
                None -> "Ready"
              }
          }),
          html.span([], [
            html.text(case model.compare_error {
              Some(reason) -> reason
              None -> "PID and clock origins are excluded from alignment"
            }),
          ]),
        ],
      ),
    ],
  )
}

fn preset_option(value: String, label: String) -> Element(workspace.Msg) {
  html.option([attribute.value(value)], label)
}

fn capture_busy(phase: workspace.CapturePhase) -> Bool {
  case phase {
    workspace.Arming | workspace.Armed | workspace.Cancelling -> True
    _ -> False
  }
}

fn capture_arm_disabled(phase: workspace.CapturePhase) -> Bool {
  case phase {
    workspace.Unavailable -> True
    _ -> capture_busy(phase)
  }
}

fn capture_ready(phase: workspace.CapturePhase) -> Bool {
  case phase {
    workspace.Ready(_, _) -> True
    _ -> False
  }
}

fn capture_phase_label(phase: workspace.CapturePhase) -> String {
  case phase {
    workspace.Unavailable -> "Offline session"
    workspace.Idle -> "Idle"
    workspace.Arming -> "Arming"
    workspace.Armed -> "Armed"
    workspace.Cancelling -> "Cancelling"
    workspace.Ready(count, outcome) ->
      "Sealed · " <> int.to_string(count) <> " events · " <> outcome
    workspace.Failed(reason) -> "Failed · " <> reason
  }
}

fn workspace_header(model: workspace.Model) -> Element(workspace.Msg) {
  html.header([attribute.class("topbar")], [
    html.div([attribute.class("brand")], [
      html.span([attribute.class("brand-mark"), attribute.aria_hidden(True)], [
        html.text("BT"),
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
      mode_button(model.mode, workspace.Team, "Team traces", "4"),
    ]),
    html.div([attribute.class("topbar-actions")], [
      html.label([attribute.class("search")], [
        html.span([attribute.class("sr-only")], [html.text("Search events")]),
        html.input([
          attribute.id("event-search"),
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
          attribute.aria_keyshortcuts("Control+K Meta+K"),
          event.on_click(workspace.UserOpenedPalette),
        ],
        [html.text("Commands  " <> appearance.modifier_label() <> "K")],
      ),
      html.button(
        [
          attribute.class("quiet-button theme-button"),
          attribute.aria_label("Change color theme"),
          event.on_click(workspace.UserCycledTheme),
        ],
        [html.text("Theme · " <> theme_label(model.theme))],
      ),
    ]),
  ])
}

fn theme_label(theme: workspace.Theme) -> String {
  case theme {
    workspace.SystemTheme -> "System"
    workspace.LightTheme -> "Light"
    workspace.DarkTheme -> "Dark"
  }
}

fn mobile_mode_navigation(model: workspace.Model) -> Element(workspace.Msg) {
  html.nav(
    [
      attribute.class("mobile-mode-navigation"),
      attribute.aria_label("Mobile workspace mode"),
    ],
    [
      mode_button(model.mode, workspace.Capture, "Capture", "1"),
      mode_button(model.mode, workspace.Live, "Live", "2"),
      mode_button(model.mode, workspace.Compare, "Compare", "3"),
      mode_button(model.mode, workspace.Team, "Team", "4"),
    ],
  )
}

fn mobile_drawers(model: workspace.Model) -> Element(workspace.Msg) {
  html.div([attribute.class("mobile-drawers")], [
    html.details([attribute.class("mobile-session-drawer")], [
      html.summary([], [html.text("Session navigator")]),
      session_navigator(model),
    ]),
    html.details([attribute.class("mobile-inspector-drawer")], [
      html.summary([], [html.text("Inspector")]),
      inspector(model),
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

fn session_navigator(model: workspace.Model) -> Element(workspace.Msg) {
  case model.mode {
    workspace.Team -> team_navigator(model)
    _ -> capture_navigator(model)
  }
}

fn capture_navigator(model: workspace.Model) -> Element(workspace.Msg) {
  html.nav(
    [
      attribute.class("navigator panel"),
      attribute.aria_label("Session navigator"),
      attribute.attribute("tabindex", "0"),
    ],
    [
      panel_heading("Nodes & sessions", "01"),
      html.section([], [
        html.h2([], [html.text("Current target")]),
        html.div([attribute.class("node-card selected")], [
          html.span([attribute.class("status-dot healthy")], []),
          html.span([], [
            html.strong([], [html.text("Attached BEAM session")]),
            html.span([], [html.text(capture_phase_label(model.capture_phase))]),
          ]),
        ]),
      ]),
      html.section([], [
        html.h2([], [html.text("Capture session")]),
        html.p([], [
          html.text(case model.capture_phase, string.trim(model.trigger_input) {
            workspace.Ready(count, _), "" ->
              "Sealed archive · " <> int.to_string(count) <> " events"
            _, "" -> "No trigger armed"
            _, trigger -> trigger
          }),
        ]),
      ]),
    ],
  )
}

fn team_navigator(model: workspace.Model) -> Element(workspace.Msg) {
  html.nav(
    [
      attribute.class("navigator panel"),
      attribute.aria_label("Team trace navigator"),
      attribute.attribute("tabindex", "0"),
    ],
    [
      panel_heading("Team trace library", "01"),
      html.section([], [
        html.h2([], [html.text("Retention-safe sessions")]),
        html.p([], [
          html.text(
            int.to_string(list.length(model.team_traces))
            <> " traces loaded · max 100",
          ),
        ]),
        html.button(
          [
            attribute.class("quiet-button"),
            attribute.disabled(model.team_loading),
            event.on_click(workspace.UserRequestedTeamTraces),
          ],
          [html.text("Refresh traces")],
        ),
      ]),
      html.section([], [
        html.h2([], [html.text("Privacy")]),
        html.p([], [
          html.text(
            "Raw and unknown trace contents remain locked unless your combined role permits access.",
          ),
        ]),
      ]),
    ],
  )
}

fn causal_workspace(model: workspace.Model) -> Element(workspace.Msg) {
  case model.mode {
    workspace.Live -> live_workspace(model)
    workspace.Compare -> compare_workspace(model)
    workspace.Capture -> event_workspace(model)
    workspace.Team -> team_workspace(model)
  }
}

fn team_workspace(model: workspace.Model) -> Element(workspace.Msg) {
  html.section(
    [
      attribute.class("causal panel team-traces-panel"),
      attribute.aria_label("Team trace library"),
    ],
    [
      html.div([attribute.class("panel-toolbar")], [
        html.div([], [
          html.p([attribute.class("eyebrow")], [html.text("team")]),
          html.h2([], [html.text("Session-scoped traces")]),
        ]),
        html.span(
          [attribute.class("window-count"), attribute.aria_live("polite")],
          [html.text(team_status(model))],
        ),
      ]),
      case model.team_error {
        Some(reason) ->
          html.p([attribute.class("error-state"), attribute.role("alert")], [
            html.text(reason),
          ])
        None -> html.div([], [])
      },
      team_compare_bar(model),
      team_trace_table(model),
      case model.team_next_cursor {
        Some(_) ->
          html.button(
            [
              attribute.class("quiet-button"),
              attribute.disabled(model.team_loading),
              event.on_click(workspace.UserRequestedMoreTeamTraces),
            ],
            [html.text("Load more traces")],
          )
        None -> html.div([], [])
      },
      team_event_section(model),
    ],
  )
}

fn team_compare_bar(model: workspace.Model) -> Element(workspace.Msg) {
  let count = list.length(model.selected_team_trace_ids)
  html.div([attribute.class("team-compare-bar")], [
    html.span([attribute.aria_live("polite")], [
      html.text(int.to_string(count) <> " of 20 selected for comparison"),
    ]),
    html.button(
      [
        attribute.class("quiet-button"),
        attribute.disabled(count < 2 || count > 20),
        event.on_click(workspace.UserRequestedTeamCompare),
      ],
      [html.text("Compare selected traces")],
    ),
  ])
}

fn team_status(model: workspace.Model) -> String {
  case model.team_loading {
    True -> "Loading traces"
    False -> int.to_string(list.length(model.team_traces)) <> " loaded"
  }
}

fn team_trace_table(model: workspace.Model) -> Element(workspace.Msg) {
  case model.team_traces {
    [] ->
      html.div([attribute.class("empty-state")], [
        html.p([], [html.text("No team traces are available.")]),
      ])
    traces ->
      html.div([attribute.class("event-table-wrap team-trace-table")], [
        html.table([attribute.aria_label("Team traces")], [
          html.thead([], [
            html.tr([], [
              html.th([], [html.text("Compare")]),
              html.th([], [html.text("Trace")]),
              html.th([], [html.text("Status")]),
              html.th([], [html.text("Node / MFA")]),
              html.th([], [html.text("Privacy")]),
              html.th([], [html.text("Events")]),
              html.th([], [html.text("Received")]),
            ]),
          ]),
          html.tbody(
            [],
            list.map(traces, fn(trace) { team_trace_row(model, trace) }),
          ),
        ]),
      ])
  }
}

fn team_trace_row(
  model: workspace.Model,
  trace: workspace.TeamTrace,
) -> Element(workspace.Msg) {
  html.tr(
    [
      attribute.class(case trace.locked {
        True -> "locked"
        False -> ""
      }),
    ],
    [
      html.td([], [
        html.button(
          [
            attribute.class("compare-selector"),
            attribute.aria_pressed(
              case list.contains(model.selected_team_trace_ids, trace.id) {
                True -> "true"
                False -> "false"
              },
            ),
            attribute.aria_label("Select " <> trace.id <> " for comparison"),
            event.on_click(workspace.UserToggledTeamCompare(trace.id)),
          ],
          [
            html.text(
              case list.contains(model.selected_team_trace_ids, trace.id) {
                True -> "Selected"
                False -> "Select"
              },
            ),
          ],
        ),
      ]),
      html.td([], [
        html.button(
          [
            attribute.class("event-link"),
            event.on_click(workspace.UserSelectedTeamTrace(trace.id)),
          ],
          [html.text(trace.id)],
        ),
      ]),
      html.td([], [
        html.span([attribute.class("kind-pill")], [
          html.text(trace.delivery_status),
        ]),
      ]),
      html.td([], [
        html.text(
          trace.node
          <> " · "
          <> trace.module
          <> ":"
          <> trace.function
          <> "/"
          <> int.to_string(trace.arity),
        ),
      ]),
      html.td([], [
        html.text(trace.privacy),
        case trace.locked {
          True ->
            html.span(
              [
                attribute.class("locked-badge"),
                attribute.aria_label("Content locked"),
              ],
              [html.text(" Locked")],
            )
          False -> html.span([], [])
        },
      ]),
      html.td([], [html.text(int.to_string(trace.event_count))]),
      html.td([], [html.text(int.to_string(trace.received_at_ms) <> " ms")]),
    ],
  )
}

fn team_event_section(model: workspace.Model) -> Element(workspace.Msg) {
  case workspace.selected_team_trace(model) {
    None ->
      html.div([attribute.class("empty-state")], [
        html.p([], [
          html.text("Select a trace to inspect its bounded event page."),
        ]),
      ])
    Some(trace) if trace.locked ->
      html.div([attribute.class("empty-state locked-trace")], [
        html.h3([], [html.text("Trace contents locked")]),
        html.p([], [
          html.text(
            "This page does not request or render raw payloads without ViewRawTrace permission.",
          ),
        ]),
      ])
    Some(trace) ->
      html.section([attribute.class("team-events")], [
        html.h3([], [html.text("Events · " <> trace.id)]),
        case model.team_events_error {
          Some(reason) -> html.p([attribute.role("alert")], [html.text(reason)])
          None ->
            event_table(model.team_events, case model.team_events_loading {
              True -> "Loading trace events…"
              False -> "This trace page has no events"
            })
        },
        case model.team_events_next_cursor {
          Some(_) ->
            html.button(
              [
                attribute.class("quiet-button"),
                attribute.disabled(model.team_events_loading),
                event.on_click(workspace.UserRequestedMoreTeamEvents),
              ],
              [html.text("Load more events")],
            )
          None -> html.div([], [])
        },
      ])
  }
}

fn compare_workspace(model: workspace.Model) -> Element(workspace.Msg) {
  let items = case model.compare_report {
    None -> []
    Some(report) ->
      report.reports
      |> list.flat_map(fn(run) {
        list.map(run.items, fn(item) { ComparedItem(run.path, item) })
      })
  }
  html.section(
    [
      attribute.class("causal panel compare-panel"),
      attribute.aria_label("Trace comparison"),
    ],
    [
      html.div([attribute.class("panel-toolbar")], [
        html.div([], [
          html.p([attribute.class("eyebrow")], [html.text("compare")]),
          html.h2([], [html.text("PID-independent causal alignment")]),
        ]),
        html.span(
          [attribute.class("window-count"), attribute.aria_live("polite")],
          [html.text(compare_summary(model))],
        ),
      ]),
      case model.compare_report {
        None ->
          html.div([attribute.class("empty-state compare-empty")], [
            html.p([], [
              html.text(
                "Enter two or more local .beamtrace paths. The first run is the baseline.",
              ),
            ]),
          ])
        Some(report) ->
          html.div([attribute.class("compare-results")], [
            divergence_summary(report.reports),
            html.div([attribute.class("canvas-frame")], [
              html.canvas([
                attribute.id("causal-canvas"),
                attribute.attribute("width", "1600"),
                attribute.attribute("height", "620"),
                attribute.aria_hidden(True),
              ]),
            ]),
            event_table(
              workspace.visible_events(model),
              event_table_empty_reason(model),
            ),
            alignment_table(items),
            statistics_table(report.statistics),
          ])
      },
    ],
  )
}

fn compare_summary(model: workspace.Model) -> String {
  case model.compare_loading, model.compare_error, model.compare_report {
    True, _, _ -> "Loading bounded trace set…"
    False, Some(reason), _ -> "Compare unavailable · " <> reason
    False, None, None -> "No comparison loaded"
    False, None, Some(report) -> {
      let added =
        list.fold(report.reports, 0, fn(total, run) { total + run.added })
      let removed =
        list.fold(report.reports, 0, fn(total, run) { total + run.removed })
      let changed =
        list.fold(report.reports, 0, fn(total, run) { total + run.changed })
      let ambiguous =
        list.fold(report.reports, 0, fn(total, run) {
          total + run.ambiguity_count
        })
      int.to_string(report.run_count)
      <> " runs · +"
      <> int.to_string(added)
      <> " −"
      <> int.to_string(removed)
      <> " ~"
      <> int.to_string(changed)
      <> " ambiguous "
      <> int.to_string(ambiguous)
    }
  }
}

fn divergence_summary(
  reports: List(workspace.CompareRun),
) -> Element(workspace.Msg) {
  let path = first_divergence_path(reports)
  html.div(
    [
      attribute.class("divergence-summary"),
      attribute.aria_label("First divergence causal path"),
    ],
    [
      html.strong([], [html.text("First divergence")]),
      html.span([], [
        html.text(case path {
          [] -> " · none established"
          _ -> " · " <> string.join(path, " → ")
        }),
      ]),
    ],
  )
}

fn first_divergence_path(reports: List(workspace.CompareRun)) -> List(String) {
  case reports {
    [] -> []
    [run, ..rest] ->
      case run.first_divergence_path {
        [] -> first_divergence_path(rest)
        path -> path
      }
  }
}

fn alignment_table(rows: List(ComparedItem)) -> Element(workspace.Msg) {
  html.div([attribute.class("event-table-wrap compare-alignment")], [
    html.table([attribute.aria_label("Accessible trace alignment table")], [
      html.thead([], [
        html.tr([], [
          html.th([], [html.text("Candidate")]),
          html.th([], [html.text("Status")]),
          html.th([], [html.text("Baseline event")]),
          html.th([], [html.text("Candidate event")]),
          html.th([], [html.text("Latency Δ")]),
          html.th([], [html.text("Reason")]),
        ]),
      ]),
      html.tbody([], list.map(rows, alignment_row)),
    ]),
  ])
}

fn alignment_row(row: ComparedItem) -> Element(workspace.Msg) {
  html.tr([attribute.class(compare_status_class(row.item.status))], [
    html.td([], [html.text(row.path)]),
    html.td([], [
      html.span([attribute.class("kind-pill")], [html.text(row.item.status)]),
    ]),
    html.td([], [html.text(or_dash(row.item.left_id))]),
    html.td([], [html.text(or_dash(row.item.right_id))]),
    html.td([], [html.text(latency_delta(row.item))]),
    html.td([], [html.text(or_dash(row.item.reason))]),
  ])
}

fn compare_status_class(status: String) -> String {
  case status {
    "added" | "removed" | "changed" -> "anomalous"
    _ -> ""
  }
}

fn latency_delta(item: workspace.CompareItem) -> String {
  case item.status {
    "matched" -> time_estimate_label(item.latency_delta)
    _ -> "—"
  }
}

fn or_dash(value: String) -> String {
  case value {
    "" -> "—"
    _ -> value
  }
}

fn statistics_table(
  rows: List(workspace.BranchStatistic),
) -> Element(workspace.Msg) {
  html.div([attribute.class("event-table-wrap compare-statistics")], [
    html.table([attribute.aria_label("Multi-run branch statistics")], [
      html.thead([], [
        html.tr([], [
          html.th([], [html.text("Logical branch signature")]),
          html.th([], [html.text("Latency")]),
          html.th([], [html.text("Occurrence")]),
        ]),
      ]),
      html.tbody(
        [],
        list.map(rows, fn(row) {
          html.tr([], [
            html.td([], [html.text(row.signature)]),
            html.td([], [
              html.text(
                "p50 "
                <> time_summary_label(row.p50)
                <> " · p95 "
                <> time_summary_label(row.p95),
              ),
            ]),
            html.td([], [
              html.text(
                int.to_string(row.occurrences)
                <> "/"
                <> int.to_string(row.total_runs)
                <> " runs",
              ),
            ]),
          ])
        }),
      ),
    ]),
  ])
}

fn event_workspace(model: workspace.Model) -> Element(workspace.Msg) {
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
          html.h2([], [
            html.text(case model.mode, model.capture_phase {
              workspace.Capture, workspace.Ready(_, _) ->
                "Sealed causal observation"
              _, _ -> mode_title(model.mode)
            }),
          ]),
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
      evidence_overview(model),
      html.div([attribute.class("canvas-frame")], [
        html.canvas([
          attribute.id("causal-canvas"),
          attribute.attribute("width", "1600"),
          attribute.attribute("height", "620"),
          attribute.aria_hidden(True),
        ]),
      ]),
      event_table(visible, event_table_empty_reason(model)),
    ],
  )
}

fn evidence_overview(model: workspace.Model) -> Element(workspace.Msg) {
  let #(exact, inferred) =
    list.fold(workspace.visible_events(model), #(0, 0), fn(counts, row) {
      case row.evidence {
        workspace.Exact -> #(counts.0 + 1, counts.1)
        workspace.Inferred(_, _) -> #(counts.0, counts.1 + 1)
      }
    })
  let outcome = case model.capture_phase {
    workspace.Ready(_, summary) -> summary
    workspace.Armed | workspace.Arming | workspace.Cancelling ->
      "Observation has not ended"
    workspace.Failed(reason) -> "Capture failed · " <> reason
    _ -> "No sealed observation outcome is available"
  }
  let delivery = case string.contains(outcome, "delivery verified") {
    True -> "Verified by final node receipts"
    False -> "Not verified; inspect integrity issues before drawing conclusions"
  }
  let inference_basis =
    model.events
    |> list.find_map(fn(row) {
      case row.evidence {
        workspace.Exact -> Error(Nil)
        workspace.Inferred(method, reason) -> Ok(method <> " · " <> reason)
      }
    })
  html.section(
    [
      attribute.class("evidence-overview"),
      attribute.aria_label("What this trace establishes and does not establish"),
    ],
    [
      html.div([], [
        html.span([], [html.text("Observation end")]),
        html.strong([], [html.text(outcome)]),
      ]),
      html.div([], [
        html.span([], [html.text("Delivery verification")]),
        html.strong([], [html.text(delivery)]),
      ]),
      html.div([], [
        html.span([], [html.text("Integrity / boundaries")]),
        html.strong([], [
          html.text(
            int.to_string(list.length(model.graph_boundaries))
            <> " causal boundaries · "
            <> case model.graph_error {
              Some(_) -> "graph issue; reload or validate the archive"
              None -> "no graph loader issue"
            },
          ),
        ]),
      ]),
      html.div([], [
        html.span([], [html.text("Evidence basis")]),
        html.strong([], [
          html.text(
            int.to_string(exact)
            <> " visible Exact · "
            <> int.to_string(inferred)
            <> " visible Inferred"
            <> case inference_basis {
              Ok(value) -> " · first basis: " <> value
              Error(_) -> ""
            },
          ),
        ]),
      ]),
      html.p([], [
        html.text(
          "Known: recorded ordering and stated inference inputs. Unknown: work outside the observation end, missing delivery, and every marked boundary.",
        ),
      ]),
    ],
  )
}

fn live_workspace(model: workspace.Model) -> Element(workspace.Msg) {
  let rows = workspace.filtered_live_rows(model)
  html.section(
    [attribute.class("causal panel"), attribute.aria_label("Live processes")],
    [
      html.div([attribute.class("panel-toolbar")], [
        html.div([], [
          html.p([attribute.class("eyebrow")], [html.text("live")]),
          html.h2([], [html.text("Bounded process sampling")]),
        ]),
        html.div([attribute.class("toolbar-actions")], [
          html.span([attribute.class("window-count")], [
            html.text(
              "Topology · supervision "
              <> int.to_string(list.length(model.live_supervision))
              <> " · spawn "
              <> int.to_string(list.length(model.live_spawn))
              <> " · links "
              <> int.to_string(list.length(model.live_links)),
            ),
          ]),
          html.span(
            [attribute.class("window-count"), attribute.aria_live("polite")],
            [html.text(live_status(model, list.length(rows)))],
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
      ]),
      live_table(model, rows),
    ],
  )
}

fn live_status(model: workspace.Model, visible_count: Int) -> String {
  case model.live_loading, model.live_error {
    True, _ -> "Refreshing bounded sample…"
    False, Some(reason) -> "Live unavailable · " <> reason
    False, None ->
      int.to_string(visible_count)
      <> " processes · Generation "
      <> int.to_string(model.live_generation)
  }
}

fn live_table(
  model: workspace.Model,
  rows: List(workspace.LiveRow),
) -> Element(workspace.Msg) {
  html.div([attribute.class("event-table-wrap")], [
    html.table([attribute.aria_label("Accessible live process table")], [
      html.thead([], [
        html.tr([], [
          html.th([], [html.text("Process")]),
          html.th([], [html.text("PID")]),
          html.th([], [html.text("Mailbox")]),
          html.th([], [html.text("Memory")]),
          html.th([], [html.text("Reductions")]),
          html.th([], [html.text("Status")]),
          html.th([], [html.text("Anomalies")]),
          html.th([], [html.text("Evidence")]),
        ]),
      ]),
      html.tbody([], list.map(rows, fn(row) { live_row(model, row) })),
    ]),
  ])
}

fn live_row(
  model: workspace.Model,
  row: workspace.LiveRow,
) -> Element(workspace.Msg) {
  let findings = workspace.live_findings_for(model, row.pid)
  html.tr(
    [
      attribute.class(case findings {
        [] -> ""
        _ -> "anomalous"
      }),
      event.on_click(workspace.UserSelectedLiveProcess(row.pid)),
    ],
    [
      html.td([], [
        html.button([attribute.class("event-link")], [html.text(row.label)]),
      ]),
      html.td([], [html.text(row.pid)]),
      html.td([], [html.text(int.to_string(row.mailbox_len))]),
      html.td([], [html.text(int.to_string(row.memory_bytes) <> " B")]),
      html.td([], [html.text(int.to_string(row.reductions))]),
      html.td([], [html.text(row.status)]),
      html.td([], [html.text(finding_names(findings))]),
      html.td([], [html.text(live_evidence_label(findings))]),
    ],
  )
}

fn finding_names(findings: List(workspace.LiveFinding)) -> String {
  case findings {
    [] -> "None"
    _ -> findings |> list.map(fn(finding) { finding.kind }) |> string.join(", ")
  }
}

fn live_evidence_label(findings: List(workspace.LiveFinding)) -> String {
  case findings {
    [] -> "Exact sample"
    [finding, ..] -> evidence_label(finding.evidence)
  }
}

fn event_table(
  rows: List(workspace.EventRow),
  empty_reason: String,
) -> Element(workspace.Msg) {
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
      html.tbody([], case rows {
        [] -> [
          html.tr([attribute.class("empty-state")], [
            html.td([attribute.attribute("colspan", "5")], [
              html.text(empty_reason),
            ]),
          ]),
        ]
        _ -> list.map(rows, event_row)
      }),
    ]),
  ])
}

fn event_table_empty_reason(model: workspace.Model) -> String {
  case model.loading, workspace.remote_query(model) {
    True, _ -> "Loading event window…"
    False, "" ->
      case
        !model.show_internal && list.any(model.events, fn(row) { row.internal })
      {
        True ->
          "No events in this window · Expand OTP noise to show system processes"
        False -> "No events in this window · widen the window or record again"
      }
    False, _ -> "No events match · clear the search"
  }
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
      html.td([attribute.title(time_format.raw_label(row.time))], [
        html.text(
          time_format.offset_label(row.timestamp_ns)
          <> " · "
          <> time_format.instant_label(row.time),
        ),
      ]),
      html.td([], [html.text(evidence_label(row.evidence))]),
    ],
  )
}

fn inspector(model: workspace.Model) -> Element(workspace.Msg) {
  case model.mode {
    workspace.Live -> live_inspector(model)
    workspace.Compare -> compare_inspector(model)
    workspace.Capture -> event_inspector(model)
    workspace.Team -> team_inspector(model)
  }
}

fn team_inspector(model: workspace.Model) -> Element(workspace.Msg) {
  html.aside(
    [
      attribute.class("inspector panel"),
      attribute.aria_label("Team trace inspector"),
      attribute.attribute("tabindex", "0"),
    ],
    [
      panel_heading("Trace policy", "03"),
      case workspace.selected_team_trace(model) {
        None -> html.p([], [html.text("Select a trace")])
        Some(trace) ->
          html.div([], [
            definition("Trace", trace.id),
            definition("Delivery status", trace.delivery_status),
            definition("Privacy", case trace.locked {
              True -> trace.privacy <> " · locked"
              False -> trace.privacy
            }),
            definition("Legal hold", case trace.legal_hold {
              True -> "enabled"
              False -> "disabled"
            }),
            html.button(
              [
                attribute.class("quiet-button"),
                event.on_click(workspace.UserRequestedTraceHold(
                  trace.id,
                  !trace.legal_hold,
                )),
              ],
              [
                html.text(case trace.legal_hold {
                  True -> "Release legal hold"
                  False -> "Place legal hold"
                }),
              ],
            ),
            html.p([], [
              html.text(
                "Legal hold changes require an Admin role and are CSRF-protected and audited.",
              ),
            ]),
          ])
      },
    ],
  )
}

fn compare_inspector(model: workspace.Model) -> Element(workspace.Msg) {
  html.aside(
    [
      attribute.class("inspector panel"),
      attribute.aria_label("Compare inspector"),
      attribute.attribute("tabindex", "0"),
    ],
    [
      panel_heading("Compare inspector", "03"),
      case model.compare_report {
        None ->
          html.div([attribute.class("empty-state")], [
            html.p([], [
              html.text("Run a comparison to inspect branch statistics."),
            ]),
          ])
        Some(report) ->
          html.div([attribute.class("inspector-content")], [
            definition("Baseline", report.baseline),
            definition("Runs", int.to_string(report.run_count)),
            definition(
              "Aligned candidates",
              int.to_string(list.length(report.reports)),
            ),
            definition(
              "Branch signatures",
              int.to_string(list.length(report.statistics)),
            ),
            definition(
              "Normalization",
              "logical actor · term shape · root-relative time",
            ),
          ])
      },
    ],
  )
}

fn event_inspector(model: workspace.Model) -> Element(workspace.Msg) {
  html.aside(
    [
      attribute.class("inspector panel"),
      attribute.aria_label("Event inspector"),
      attribute.attribute("tabindex", "0"),
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
    definition("Calibrated time", time_format.instant_label(row.time)),
    definition("Raw calibrated bounds", time_format.raw_label(row.time)),
    definition(
      "Node-local offset",
      time_format.offset_label(row.timestamp_ns)
        <> " ("
        <> int.to_string(row.timestamp_ns)
        <> " ns, not cross-node comparable)",
    ),
    definition(
      "Duration",
      time_format.duration_label(row.duration_ns)
        <> " ("
        <> int.to_string(row.duration_ns)
        <> " ns)",
    ),
    definition("Boundary", event_boundary_label(model, row.id)),
    definition("Source", "Unavailable in this event metadata"),
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

fn event_boundary_label(model: workspace.Model, event_id: String) -> String {
  let boundaries =
    model.graph_boundaries
    |> list.filter(fn(boundary) { boundary.event_id == event_id })
    |> list.map(fn(boundary) { boundary.kind <> " · " <> boundary.reason })
  case boundaries {
    [] -> "None observed"
    _ -> string.join(boundaries, "; ")
  }
}

fn live_inspector(model: workspace.Model) -> Element(workspace.Msg) {
  html.aside(
    [
      attribute.class("inspector panel"),
      attribute.aria_label("Process inspector"),
      attribute.attribute("tabindex", "0"),
    ],
    [
      panel_heading("Process inspector", "03"),
      case workspace.selected_live_process(model) {
        Error(_) ->
          html.div([attribute.class("empty-state")], [
            html.p([], [
              html.text(
                "Select a process to inspect sampled metadata and evidence.",
              ),
            ]),
          ])
        Ok(row) -> live_inspector_process(model, row)
      },
    ],
  )
}

fn live_inspector_process(
  model: workspace.Model,
  row: workspace.LiveRow,
) -> Element(workspace.Msg) {
  let findings = workspace.live_findings_for(model, row.pid)
  html.div([attribute.class("inspector-content")], [
    html.div([attribute.class("inspector-title")], [
      html.div([], [
        html.p([attribute.class("eyebrow")], [html.text(row.status)]),
        html.h2([], [html.text(row.label)]),
      ]),
    ]),
    definition("PID", row.pid <> " @ " <> row.node),
    definition("Initial call", row.initial_call),
    definition("Current function", row.current_function),
    definition("Mailbox", int.to_string(row.mailbox_len)),
    definition("Memory", int.to_string(row.memory_bytes) <> " bytes"),
    definition("Heap", int.to_string(row.total_heap_words) <> " words"),
    definition("Ancestors", list_text(row.ancestors)),
    definition("Links", list_text(row.links)),
    html.section([attribute.class("finding-list")], [
      html.h3([], [html.text("Anomaly evidence")]),
      case findings {
        [] ->
          html.p([], [html.text("No anomaly crossed its hysteresis threshold.")])
        _ ->
          html.ul(
            [],
            list.map(findings, fn(finding) {
              html.li([], [
                html.strong([], [html.text(finding.kind)]),
                html.span([], [html.text(finding.summary)]),
                html.span([], [html.text(evidence_label(finding.evidence))]),
              ])
            }),
          )
      },
    ]),
  ])
}

fn list_text(items: List(String)) -> String {
  case items {
    [] -> "None observed"
    _ -> string.join(items, ", ")
  }
}

fn definition(label: String, value: String) -> Element(workspace.Msg) {
  html.div([attribute.class("definition")], [
    html.span([], [html.text(label)]),
    html.strong([], [html.text(value)]),
  ])
}

fn minimap(model: workspace.Model) -> Element(workspace.Msg) {
  case model.mode {
    workspace.Live ->
      html.footer(
        [
          attribute.class("minimap"),
          attribute.aria_label("Live sampling status"),
        ],
        [
          html.span([], [
            html.text(
              "Generation "
              <> int.to_string(model.live_generation)
              <> " · sampled at "
              <> int.to_string(model.live_sampled_at_ms)
              <> " ms",
            ),
          ]),
          html.span([], [
            html.text(
              int.to_string(list.length(model.live_findings))
              <> " active inferred anomalies",
            ),
          ]),
        ],
      )
    workspace.Compare ->
      html.footer(
        [attribute.class("minimap"), attribute.aria_label("Compare summary")],
        [html.span([], [html.text(compare_summary(model))])],
      )
    workspace.Capture -> event_minimap(model)
    workspace.Team ->
      html.footer(
        [attribute.class("minimap"), attribute.aria_label("Team trace status")],
        [html.span([], [html.text(team_status(model))])],
      )
  }
}

fn event_minimap(model: workspace.Model) -> Element(workspace.Msg) {
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
            [
              attribute.autofocus(True),
              event.on_click(workspace.UserChoseCaptureAction),
            ],
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
          html.button(
            [event.on_click(workspace.UserSelectedMode(workspace.Team))],
            [html.text("Open Team trace library")],
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
    workspace.Team -> "team"
  }
}

fn mode_title(mode: workspace.Mode) -> String {
  case mode {
    workspace.Capture -> "Bounded causal observation"
    workspace.Live -> "Runtime signals"
    workspace.Compare -> "Trace alignment"
    workspace.Team -> "Team trace library"
  }
}

fn evidence_label(evidence: workspace.Evidence) -> String {
  case evidence {
    workspace.Exact -> "Exact"
    workspace.Inferred(method, reason) ->
      "Inferred · " <> method <> " · " <> reason
  }
}

fn time_estimate_label(estimate: workspace.TimeEstimate) -> String {
  time_format.delta_label(estimate)
}

fn time_summary_label(summary: workspace.TimeSummary) -> String {
  time_estimate_label(summary.estimate)
  <> " · "
  <> int.to_string(summary.valid_samples)
  <> " valid / "
  <> int.to_string(summary.missing_samples)
  <> " missing"
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
