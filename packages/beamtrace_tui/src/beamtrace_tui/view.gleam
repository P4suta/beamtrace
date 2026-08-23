// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_tui/model
import etui/buffer
import etui/geometry.{type Rect, Fill, Horizontal, Length, Vertical}
import etui/style
import etui/widgets/block
import etui/widgets/paragraph
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
  let rows = geometry.split(Vertical, screen, [Length(3), Fill, Length(1)])
  let #(header, body, footer) = case rows {
    [header, body, footer, ..] -> #(header, body, footer)
    _ -> #(screen, screen, screen)
  }
  let columns = geometry.split(Horizontal, body, [Length(24), Fill, Length(31)])
  let #(sidebar, timeline, inspector) = case columns {
    [sidebar, timeline, inspector, ..] -> #(sidebar, timeline, inspector)
    _ -> #(body, body, body)
  }

  buffer.buffer_new(screen)
  |> render_header(header, state)
  |> render_sidebar(sidebar, state)
  |> render_timeline(timeline, state)
  |> render_inspector(inspector, state)
  |> render_footer(footer, state)
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
    _ -> 0
  }
  let tabs =
    tabs.tabs_new(["CAPTURE", "LIVE", "COMPARE → Web"])
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
  let content =
    status
    <> "\n"
    <> node
    <> "\n\nCAPTURE\n"
    <> "#1042  current\n"
    <> "#1041  truncated\n\nARMED MFA\n"
    <> trigger
    <> "\n\nPRIVACY\nmetadata (default)"

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
  }
  let frame = panel(title, amber)
  let content = case state.screen {
    model.AttachScreen -> attach_content(state)
    model.AnomalyScreen -> anomaly_content(state)
    model.LiveScreen -> live_content(state)
    model.CaptureScreen -> causal_content(state)
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
  let content =
    "EVIDENCE\nExact\n\nCOMPLETENESS\nComplete\n\nBOUNDARY\nnone observed\n\n"
    <> input
    <> "\n\n"
    <> state.notice
    <> "\n\nACTIONS\n"
    <> "a attach\nr arm MFA\n! anomalies\n/ search\ns save\nw open Web"

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
    True -> "connected"
    False -> "offline"
  }
  paragraph.render(
    target,
    area,
    paragraph.paragraph_new(
      " a attach   r arm   ! anomalies   / search   s save   w Web   q quit  │  "
      <> status,
    )
      |> paragraph.with_style(style.new(background, amber, style.bold())),
  )
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

fn causal_content(state: model.Model) -> String {
  let rows = model.visible_events(state)
  case rows {
    [] -> "No causal events match the current search."
    _ -> rows |> list.map(format_event) |> string.join("\n│\n")
  }
}

fn anomaly_content(state: model.Model) -> String {
  case model.anomalies(state) {
    [] -> "No active anomalies. Baselines are warming."
    rows ->
      "EXPLANATION                    EVIDENCE\n"
      <> { rows |> list.map(format_event) |> string.join("\n\n") }
  }
}

fn live_content(_state: model.Model) -> String {
  "mailbox growth     ▁▂▃▅▇  +42/min\n"
  <> "reductions        ▁▁▂▆█  +3.8σ\n"
  <> "memory            ▁▂▂▃▄  18.4 MiB\n"
  <> "restart rate      ▁▁▁▅▇  4/10s\n\n"
  <> "Sampling is split across processes; full message trace is off."
}

fn format_event(event: model.Event) -> String {
  let marker = case event.anomalous {
    True -> "!"
    False -> "●"
  }
  "+"
  <> pad_offset(event.offset_us)
  <> " μs  "
  <> marker
  <> " "
  <> event.id
  <> "\n└─ "
  <> event.actor
  <> " · "
  <> event.kind
  <> " ["
  <> event.evidence
  <> "]"
}

fn pad_offset(value: Int) -> String {
  let raw = int.to_string(value)
  string.repeat("0", int.max(0, 6 - string.length(raw))) <> raw
}
