// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_tui/model
import etui/buffer
import etui/geometry.{type Rect, Breakpoint, Fill, Length, Vertical}
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/help
import etui/widgets/paragraph
import etui/widgets/statusbar
import etui/widgets/tabs
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const amber = style.Rgb(241, 188, 91)

const coral = style.Rgb(255, 115, 105)

const violet = style.Rgb(155, 123, 255)

const muted = style.Rgb(157, 149, 162)

const background = style.Rgb(12, 11, 18)

pub fn render(state: model.Model, screen: Rect) -> buffer.Buffer {
  let rows = geometry.split(Vertical, screen, [Length(3), Fill, Length(2)])
  let #(header, body, footer) = case rows {
    [header, body, footer, ..] -> #(header, body, footer)
    _ -> #(screen, screen, screen)
  }
  let columns =
    geometry.split_responsive(body, [
      Breakpoint(100, [Length(24), Fill, Length(31)]),
      Breakpoint(72, [Fill, Length(31)]),
      Breakpoint(0, [Fill]),
    ])
  let target = buffer.buffer_new(screen) |> render_header(header, state)
  let target = case columns {
    [sidebar, timeline, inspector] ->
      target
      |> render_sidebar(sidebar, state)
      |> render_timeline(timeline, state)
      |> render_inspector(inspector, state)
    [timeline, inspector] ->
      target
      |> render_timeline(timeline, state)
      |> render_inspector(inspector, state)
    [timeline] -> render_timeline(target, timeline, state)
    _ -> render_timeline(target, body, state)
  }
  render_footer(target, footer, state)
}

fn render_header(
  target: buffer.Buffer,
  area: Rect,
  state: model.Model,
) -> buffer.Buffer {
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_title(" BeamTrace · BEAM causal workbench ", block.Top)
    |> block.with_style(amber, background)
  let active = case state.screen {
    model.LiveScreen | model.AnomalyScreen -> 1
    model.TraceLibraryScreen -> 2
    model.CompareScreen -> 3
    _ -> 0
  }
  let tabs =
    tabs.tabs_new(["CAPTURE", "LIVE", "TEAM TRACES", "COMPARE"])
    |> tabs.with_active(active)
    |> tabs.with_active_style(style.new(background, amber, style.bold()))
    |> tabs.with_colors(muted, background)

  target
  |> block.render(area, frame)
  |> tabs.render(block.inner(area, frame), tabs)
}

fn render_sidebar(
  target: buffer.Buffer,
  area: Rect,
  state: model.Model,
) -> buffer.Buffer {
  let frame = panel(" NODE / SESSION ", violet)
  let node = case state.node {
    Some(value) -> value
    None -> "not attached"
  }
  let status = case state.connected {
    True -> "● connected"
    False -> "○ disconnected"
  }
  let trigger = case state.armed_trigger {
    Some(value) -> value
    None -> "not armed"
  }
  let capture = capture_phase(state.capture_phase)
  let content =
    status
    <> "\n"
    <> node
    <> "\n\nCAPTURE\n"
    <> capture
    <> "\n\nARMED MFA\n"
    <> trigger
    <> "\n\nPRIVACY\nmetadata (default)"
    <> "\n\nLIVE\ngeneration "
    <> int.to_string(state.live_generation)

  target
  |> block.render(area, frame)
  |> paragraph.render(
    block.inner(area, frame),
    paragraph.paragraph_new(content)
      |> paragraph.with_style(style.new(muted, background, style.none())),
  )
}

fn render_timeline(
  target: buffer.Buffer,
  area: Rect,
  state: model.Model,
) -> buffer.Buffer {
  let title = case state.screen {
    model.AttachScreen -> " ATTACH "
    model.CaptureScreen -> " CAPTURE · VERTICAL CAUSAL CHAIN "
    model.LiveScreen -> " LIVE · RUNTIME SIGNALS "
    model.AnomalyScreen -> " LIVE · ANOMALIES "
    model.TraceLibraryScreen -> " TEAM · TRACE LIBRARY "
    model.CompareScreen -> " COMPARE · MULTI-TRACE ALIGNMENT "
  }
  let frame = panel(title, amber)
  let content_width = block.inner(area, frame).size.width
  let content = case state.screen {
    model.AttachScreen -> attach_content(state)
    model.AnomalyScreen -> anomaly_content(state, content_width)
    model.LiveScreen -> live_content(state, content_width)
    model.CaptureScreen -> causal_content(state, content_width)
    model.TraceLibraryScreen -> team_trace_content(state, content_width)
    model.CompareScreen -> compare_content(state, content_width)
  }

  target
  |> block.render(area, frame)
  |> paragraph.render(
    block.inner(area, frame),
    paragraph.paragraph_new(content)
      |> paragraph.with_style(style.new(style.Default, background, style.none())),
  )
}

fn render_inspector(
  target: buffer.Buffer,
  area: Rect,
  state: model.Model,
) -> buffer.Buffer {
  let frame = panel(" EVENT / ACTIONS ", coral)
  let input = case state.focus {
    model.AttachFocus -> "attach> " <> state.node_input <> "▌"
    model.ArmFocus -> "arm MFA> " <> state.trigger_input <> "▌"
    model.SearchFocus -> "search> " <> state.query <> "▌"
    model.SaveFocus -> "save> " <> state.save_input <> "▌"
    model.NormalFocus -> "Press a command key"
  }
  let content = case state.screen {
    model.CompareScreen -> compare_inspector_content(state)
    _ ->
      "SESSION\n"
      <> capture_phase(state.capture_phase)
      <> "\n\nEVENT EVIDENCE\nSelect an event from the causal chain\n\n"
      <> input
      <> "\n\n"
      <> state.notice
      <> "\n\nACTIONS\n"
      <> "a attach\nr arm MFA\nx cancel\n! anomalies\n/ search\ns save\nw open Web"
  }

  target
  |> block.render(area, frame)
  |> paragraph.render(
    block.inner(area, frame),
    paragraph.paragraph_new(content)
      |> paragraph.with_style(style.new(muted, background, style.none())),
  )
}

fn render_footer(
  target: buffer.Buffer,
  area: Rect,
  state: model.Model,
) -> buffer.Buffer {
  let status = case state.connected {
    True -> "● connected"
    False -> "○ offline"
  }
  let rows = geometry.split(Vertical, area, [Length(1), Length(1)])
  let #(help_area, status_area) = case rows {
    [help_area, status_area, ..] -> #(help_area, status_area)
    _ -> #(area, area)
  }
  let shortcuts =
    help.help_new([
      help.binding(["q"], "quit"),
      help.binding(["a"], "attach"),
      help.binding(["r"], "arm"),
      help.binding(["t"], "traces"),
      help.binding(["d"], "compare"),
      help.binding(["!"], "anomalies"),
      help.binding(["/"], "search"),
      help.binding(["s"], "save"),
      help.binding(["w"], "Web"),
    ])
    |> help.with_key_color(amber)
    |> help.with_description_color(muted)
    |> help.with_bg(background)
  let bar =
    statusbar.statusbar_new()
    |> statusbar.with_left([span.line_plain(status)])
    |> statusbar.with_center([span.line_plain(state.notice)])
    |> statusbar.with_right([span.line_plain("BeamTrace")])
    |> statusbar.with_style(amber, background)

  target
  |> help.render(help_area, shortcuts)
  |> statusbar.render(status_area, bar)
}

fn panel(title: String, colour: style.Color) -> block.Block {
  block.block_new()
  |> block.with_border(block.Single)
  |> block.with_title(title, block.Top)
  |> block.with_padding(1, 1, 1, 1)
  |> block.with_style(colour, background)
  |> block.with_bg_fill
}

fn attach_content(state: model.Model) -> String {
  "Attach to a Gleam, Elixir, or Erlang node.\n\n"
  <> "Node name\n  "
  <> state.node_input
  <> "▌\n\nCookie is read from --cookie-file, environment, or secure prompt.\n"
  <> "It is never accepted as a plaintext CLI argument.\n\nEnter attach · Esc cancel"
}

fn causal_content(state: model.Model, width: Int) -> String {
  let rows = model.visible_events(state)
  case rows {
    [] -> "No causal events match the current search."
    _ ->
      rows
      |> list.map(fn(event) { format_event(event, width) })
      |> string.join("\n│\n")
  }
}

fn anomaly_content(state: model.Model, width: Int) -> String {
  case model.anomalies(state) {
    [] -> "No active anomalies. Baselines are warming."
    rows ->
      "EXPLANATION                    EVIDENCE\n"
      <> {
        rows
        |> list.map(fn(event) { format_event(event, width) })
        |> string.join("\n\n")
      }
  }
}

fn live_content(state: model.Model, width: Int) -> String {
  case model.visible_live_events(state) {
    [] ->
      state.live_summary
      <> "\n\nWaiting for bounded process samples.\n\nFull message tracing remains off."
    rows ->
      state.live_summary
      <> "\nGeneration "
      <> int.to_string(state.live_generation)
      <> "\n\n"
      <> {
        rows
        |> list.map(fn(event) { format_event(event, width) })
        |> string.join("\n│\n")
      }
  }
}

fn capture_phase(phase: model.CapturePhase) -> String {
  case phase {
    model.CaptureUnavailable -> "unavailable"
    model.CaptureIdle -> "idle"
    model.CaptureArming -> "arming"
    model.CaptureArmed -> "armed"
    model.CaptureCancelling -> "cancelling"
    model.CaptureReady(count, outcome_summary) ->
      "sealed · " <> int.to_string(count) <> " events · " <> outcome_summary
    model.CaptureFailed(reason) -> "failed · " <> reason
  }
}

fn format_event(event: model.Event, max_width: Int) -> String {
  let marker = case event.anomalous {
    True -> "!"
    False -> "●"
  }
  let first =
    "+" <> pad_offset(event.offset_us) <> " μs  " <> marker <> " " <> event.id
  let second = "└─ " <> event.actor <> " · " <> event.kind
  let third = "   evidence: " <> event.evidence
  text.truncate(first, max_width, "…")
  <> "\n"
  <> text.truncate(second, max_width, "…")
  <> "\n"
  <> text.truncate(third, max_width, "…")
}

fn team_trace_content(state: model.Model, width: Int) -> String {
  case state.team_traces {
    [] ->
      "No team traces are available.\n\nAuthenticate in the Team workspace, then refresh the bounded trace list."
    traces ->
      "TRACE · STATUS · NODE / MFA · PRIVACY · EVENTS · RECEIVED\n"
      <> {
        traces
        |> list.index_map(fn(trace, index) {
          let marker = case index == state.selected_trace {
            True -> "› "
            False -> "  "
          }
          let privacy = case trace.locked {
            True -> trace.privacy <> " 🔒"
            False -> trace.privacy
          }
          let row_width = int.max(width, 1)
          text.truncate(marker <> trace.id, row_width, "…")
          <> "\n"
          <> text.truncate(
            "  "
              <> trace.delivery_status
              <> " · "
              <> trace.node
              <> " "
              <> trace.mfa,
            row_width,
            "…",
          )
          <> "\n"
          <> text.truncate(
            "  "
              <> privacy
              <> " · "
              <> int.to_string(trace.event_count)
              <> " events · "
              <> int.to_string(trace.received_at_ms),
            row_width,
            "…",
          )
        })
        |> string.join("\n\n")
      }
      <> "\n\n↑/↓ select · Enter inspect"
  }
}

fn compare_content(state: model.Model, width: Int) -> String {
  case state.compare_runs {
    [] ->
      "No comparison is loaded.\n\nRun beamtrace compare <2–20 archives> --tui."
    runs ->
      "CANDIDATE · ADDED · REMOVED · CHANGED · AMBIGUOUS\n"
      <> {
        runs
        |> list.map(fn(run) {
          text.truncate(run.path, int.max(width, 1), "…")
          <> "\n  +"
          <> int.to_string(run.added)
          <> "  -"
          <> int.to_string(run.removed)
          <> "  ~"
          <> int.to_string(run.changed)
          <> "  ?"
          <> int.to_string(run.ambiguity_count)
          <> "\n  first divergence: "
          <> case run.first_divergence {
            "" -> "none established"
            path -> text.truncate(path, int.max(width - 20, 1), "…")
          }
        })
        |> string.join("\n\n")
      }
  }
}

fn compare_inspector_content(state: model.Model) -> String {
  "COMPARE SUMMARY\n"
  <> int.to_string(state.compare_run_count)
  <> " traces\n\nbaseline\n"
  <> state.compare_baseline
  <> "\n\nSTATISTICS\n"
  <> int.to_string(state.compare_statistics_count)
  <> " branch signatures\n\nALIGNMENT\nlogical actor · term shape · root-relative time\n\nFirst divergence is reported only when established."
}

fn pad_offset(value: Int) -> String {
  let raw = int.to_string(value)
  string.repeat("0", int.max(0, 6 - string.length(raw))) <> raw
}
