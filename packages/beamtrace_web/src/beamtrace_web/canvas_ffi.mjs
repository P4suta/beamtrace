// SPDX-License-Identifier: Apache-2.0 OR MIT

const palette = {
  background: "#111019",
  grid: "rgba(241, 188, 91, 0.12)",
  text: "#d8d1c4",
  muted: "#817b88",
  exact: "#f1bc5b",
  receive: "#9b7bff",
  anomaly: "#ff7369",
  process: "#79b8ff",
  message: "#f1bc5b",
  spawn: "#72d6a0",
  boundary: "#817b88",
};

export function draw(root, source, zoom) {
  const canvas = root?.querySelector?.("#causal-canvas")
    ?? document.querySelector("#causal-canvas");
  if (!(canvas instanceof HTMLCanvasElement)) return;

  let payload;
  try {
    payload = JSON.parse(source);
  } catch (_) {
    return;
  }
  const rows = Array.isArray(payload) ? payload : (payload.rows ?? []);
  const edges = Array.isArray(payload) ? [] : (payload.edges ?? []);
  const boundaries = Array.isArray(payload) ? [] : (payload.boundaries ?? []);
  const divergencePath = Array.isArray(payload) ? [] : (payload.divergence_path ?? []);

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

  const usable = Math.max(width - left - right, 1) * Math.max(0.25, Math.min(zoom, 4));
  // Causal/topological API order is primary. Clock calibration is represented
  // by whiskers and never used to manufacture ordering or edges.
  const points = rows.map((row, index) => {
    const lane = Math.max(actors.indexOf(row.actor), 0);
    return {
      ...row,
      x: left + (index / Math.max(rows.length - 1, 1)) * usable,
      y: top + lane * laneHeight,
    };
  });
  const pointsById = new Map(points.map((point) => [point.id, point]));
  const divergencePairs = new Set();
  for (let index = 1; index < divergencePath.length; index += 1) {
    divergencePairs.add(`${divergencePath[index - 1]}\u0000${divergencePath[index]}`);
  }
  const renderedEdges = edges.filter((edge) =>
    pointsById.has(edge.from) || pointsById.has(edge.to)
  );
  const renderedBoundaries = boundaries.filter((boundary) =>
    pointsById.has(boundary.event_id)
  );
  canvas.dataset.edgeCount = String(renderedEdges.length);
  canvas.dataset.edgeKinds = [...new Set(renderedEdges.map((edge) => edge.kind))]
    .sort()
    .join(",");
  canvas.dataset.inferredEdgeCount = String(
    renderedEdges.filter((edge) => edge.evidence === "inferred").length,
  );
  canvas.dataset.boundaryCount = String(renderedBoundaries.length);
  canvas.dataset.estimatedTimeCount = String(
    points.filter((point) => point.time?.kind === "estimated").length,
  );
  canvas.dataset.divergenceEdgeCount = String(
    renderedEdges.filter((edge) =>
      divergencePairs.has(`${edge.from}\u0000${edge.to}`)
    ).length,
  );

  const edgeColor = (kind) => kind === "sequential_message"
    ? palette.message
    : kind === "spawned"
      ? palette.spawn
      : kind === "process_order"
        ? palette.process
        : palette.muted;

  // Draw only relationships returned by the graph API. A missing endpoint in
  // the virtual window becomes an open stub, never an invented row-to-row edge.
  edges.forEach((edge) => {
    const from = pointsById.get(edge.from);
    const to = pointsById.get(edge.to);
    if (!from && !to) return;
    const highlighted = divergencePairs.has(`${edge.from}\u0000${edge.to}`);
    context.strokeStyle = highlighted ? palette.anomaly : edgeColor(edge.kind);
    context.lineWidth = highlighted ? 3 : 1.5;
    context.setLineDash(edge.evidence === "inferred" ? [5, 4] : []);
    context.beginPath();
    if (from && to) {
      context.moveTo(from.x, from.y);
      context.bezierCurveTo(
        from.x + 24,
        from.y,
        to.x - 24,
        to.y,
        to.x,
        to.y,
      );
    } else {
      const point = from ?? to;
      const direction = from ? 1 : -1;
      context.moveTo(point.x, point.y);
      context.lineTo(point.x + direction * 30, point.y);
    }
    context.stroke();
    context.setLineDash([]);
    if (!from || !to) {
      const point = from ?? to;
      const direction = from ? 1 : -1;
      context.fillStyle = palette.background;
      context.strokeStyle = palette.boundary;
      context.beginPath();
      context.arc(point.x + direction * 30, point.y, 4, 0, Math.PI * 2);
      context.fill();
      context.stroke();
    }
  });

  boundaries.forEach((boundary) => {
    const point = pointsById.get(boundary.event_id);
    if (!point) return;
    context.strokeStyle = palette.boundary;
    context.lineWidth = 1.5;
    context.beginPath();
    context.moveTo(point.x, point.y);
    context.lineTo(point.x - 24, point.y - 12);
    context.stroke();
    context.fillStyle = palette.background;
    context.beginPath();
    context.arc(point.x - 24, point.y - 12, 4, 0, Math.PI * 2);
    context.fill();
    context.stroke();
  });

  points.forEach((point) => {
    if (point.time?.kind === "estimated") {
      let width = 12;
      try {
        const difference = BigInt(point.time.upper_ns) - BigInt(point.time.lower_ns);
        const capped = difference > 1000000000000000n
          ? 1000000000000000n
          : difference < 0n ? -difference : difference;
        width = Math.min(34, 6 + Math.log10(Number(capped) + 1) * 3);
      } catch (_) {
        width = 12;
      }
      context.strokeStyle = palette.muted;
      context.lineWidth = 1;
      context.beginPath();
      context.moveTo(point.x - width, point.y - 11);
      context.lineTo(point.x + width, point.y - 11);
      context.moveTo(point.x - width, point.y - 15);
      context.lineTo(point.x - width, point.y - 7);
      context.moveTo(point.x + width, point.y - 15);
      context.lineTo(point.x + width, point.y - 7);
      context.stroke();
    }
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
