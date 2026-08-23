// SPDX-License-Identifier: Apache-2.0 OR MIT

const palette = {
  background: "#111019",
  grid: "rgba(241, 188, 91, 0.12)",
  text: "#d8d1c4",
  muted: "#817b88",
  exact: "#f1bc5b",
  receive: "#9b7bff",
  anomaly: "#ff7369",
};

export function draw(root, source, zoom) {
  const canvas = root?.querySelector?.("#causal-canvas")
    ?? document.querySelector("#causal-canvas");
  if (!(canvas instanceof HTMLCanvasElement)) return;

  let rows;
  try {
    rows = JSON.parse(source);
  } catch (_) {
    return;
  }

  const bounds = canvas.getBoundingClientRect();
  const width = Math.max(1, Math.floor(bounds.width));
  const height = Math.max(1, Math.floor(bounds.height));
  const density = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.floor(width * density);
  canvas.height = Math.floor(height * density);

  const context = canvas.getContext("2d");
  if (!context) return;
  context.setTransform(density, 0, 0, density, 0, 0);
  context.clearRect(0, 0, width, height);
  context.fillStyle = palette.background;
  context.fillRect(0, 0, width, height);

  const actors = [...new Set(rows.map((row) => row.actor))];
  const laneCount = Math.max(actors.length, 1);
  const top = 54;
  const laneHeight = Math.max(54, (height - top - 30) / laneCount);
  const left = 120;
  const right = 36;

  context.font = "12px ui-monospace, SFMono-Regular, Consolas, monospace";
  context.lineWidth = 1;
  actors.forEach((actor, index) => {
    const y = top + index * laneHeight;
    context.strokeStyle = palette.grid;
    context.beginPath();
    context.moveTo(left, y);
    context.lineTo(width - right, y);
    context.stroke();
    context.fillStyle = palette.muted;
    context.fillText(actor, 14, y + 4);
  });

  if (rows.length === 0) {
    context.fillStyle = palette.muted;
    context.fillText("No events in this window", left, top + 20);
    return;
  }

  const first = Math.min(...rows.map((row) => Number(row.timestamp_ns)));
  const last = Math.max(...rows.map((row) => Number(row.timestamp_ns)));
  const range = Math.max(last - first, 1);
  const usable = Math.max(width - left - right, 1) * Math.max(0.25, Math.min(zoom, 4));
  const points = rows.map((row) => {
    const lane = Math.max(actors.indexOf(row.actor), 0);
    return {
      ...row,
      x: left + ((Number(row.timestamp_ns) - first) / range) * usable,
      y: top + lane * laneHeight,
    };
  });

  context.strokeStyle = "rgba(216, 209, 196, 0.32)";
  context.lineWidth = 1.5;
  for (let index = 1; index < points.length; index += 1) {
    const from = points[index - 1];
    const to = points[index];
    context.beginPath();
    context.moveTo(from.x, from.y);
    context.bezierCurveTo(
      from.x + 24,
      from.y,
      to.x - 24,
      to.y,
      to.x,
      to.y,
    );
    context.stroke();
  }

  points.forEach((point) => {
    context.fillStyle = point.anomalous
      ? palette.anomaly
      : point.kind === "receive"
        ? palette.receive
        : palette.exact;
    context.beginPath();
    context.arc(point.x, point.y, point.anomalous ? 7 : 5, 0, Math.PI * 2);
    context.fill();
    if (point.evidence === "inferred") {
      context.strokeStyle = palette.muted;
      context.setLineDash([3, 3]);
      context.stroke();
      context.setLineDash([]);
    }
  });
}

export function installShortcuts(handler) {
  if (window.__beamtraceShortcutsInstalled) return;
  window.__beamtraceShortcutsInstalled = true;
  window.addEventListener("keydown", (event) => {
    const editable = event.target instanceof HTMLInputElement
      || event.target instanceof HTMLTextAreaElement;
    const command = (event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k";
    const direct = !editable && ["1", "2", "3", "/"].includes(event.key);
    if (!command && !direct) return;
    event.preventDefault();
    handler(command ? "k" : event.key);
  });
}
