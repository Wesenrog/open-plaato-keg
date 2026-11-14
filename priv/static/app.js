/* Open Plaato Keg — shared front-end helpers (keg-weight build) */

function qs(sel, root) {
  return (root || document).querySelector(sel);
}

function ce(tag, cls, html) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
}

function esc(text) {
  const d = document.createElement("div");
  d.textContent = text == null ? "" : String(text);
  return d.innerHTML;
}

async function api(path, method, body) {
  const opts = { method: method || "GET", headers: { "Content-Type": "application/json" } };
  if (body !== undefined) opts.body = JSON.stringify(body);
  const r = await fetch(path, opts);
  const text = await r.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch (_) {
    data = null;
  }
  if (!r.ok) {
    const msg = (data && (data.error || data.message)) || r.statusText || "request failed";
    throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
  }
  return data;
}

let _toastTimer = null;
function toast(msg, isErr) {
  let t = qs(".toast");
  if (!t) {
    t = ce("div", "toast");
    document.body.appendChild(t);
  }
  t.textContent = msg;
  t.classList.toggle("err", !!isErr);
  t.classList.add("show");
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => t.classList.remove("show"), 2600);
}

/* WebSocket with auto-reconnect. onMessage gets the parsed payload. */
function connectWs(onMessage) {
  let ws;
  let closed = false;

  function open() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    ws = new WebSocket(proto + "//" + location.host + "/ws");
    ws.addEventListener("message", (e) => {
      let msg;
      try {
        msg = JSON.parse(e.data);
      } catch (_) {
        return;
      }
      onMessage(msg);
    });
    ws.addEventListener("close", () => {
      if (!closed) setTimeout(open, 2000);
    });
    ws.addEventListener("error", () => ws && ws.close());
  }

  open();
  return () => {
    closed = true;
    if (ws) ws.close();
  };
}

function loadVersion() {
  const slot = qs(".version");
  if (!slot) return;
  fetch("/api/alive")
    .then((r) => r.json())
    .then((d) => {
      if (d && d.version) slot.textContent = "v" + d.version;
    })
    .catch(() => {});
}

/* Render the shared top bar into <header data-nav="serving|kegging|devices">. */
function renderTopbar() {
  const header = qs("header[data-nav]");
  if (!header) return;
  const active = header.getAttribute("data-nav");
  const link = (id, href, text) =>
    `<a href="${href}"${id === active ? ' class="active"' : ""}>${text}</a>`;
  header.className = "topbar";
  header.innerHTML =
    "<h1>Open Plaato Keg</h1>" +
    "<nav>" +
    link("serving", "/index.html", "Serving") +
    link("kegging", "/kegging.html", "Kegging") +
    link("devices", "/devices.html", "Keg Devices") +
    "</nav>" +
    '<span class="version"></span>';
  loadVersion();
}

function num(v) {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : null;
}

/* What the scale reports as left, in kg: its weight minus the tare it holds.
   Negative when the tare is too high or the scale's zero is off. */
function netKg(rec) {
  return num(rec.amount_left) || 0;
}

/* Litres left for display: 1 litre per kg, never below zero. */
function litresLeft(rec) {
  return Math.max(0, netKg(rec));
}

/* The tare the scale holds (kg). The scale does not report it back, so this
   is what was last sent to it. */
function tareKg(rec) {
  return num(rec.empty_keg_weight) || 0;
}

/* Everything on the platform (kg): what is left plus the tare. */
function grossKg(rec) {
  return netKg(rec) + tareKg(rec);
}

function percentLeft(rec) {
  return Math.max(0, Math.min(100, num(rec.percent_of_beer_left) || 0));
}

function isPouring(rec) {
  return !!rec.is_pouring && rec.is_pouring !== "0";
}

function scaleName(rec) {
  return (rec && rec.my_label && rec.my_label.trim()) || "Scale " + String(rec.id).slice(0, 8);
}

/* Keep a Set of connected scale ids current from a WebSocket record. The
   server marks each record with `connected`; the one it sends when a scale
   drops has it false. Without the mark (older server) a record counts as
   connected. Returns true when the set changed. */
function trackConnected(set, msg) {
  const had = set.has(msg.id);
  if (msg.connected === false) set.delete(msg.id);
  else set.add(msg.id);
  return had !== set.has(msg.id);
}

document.addEventListener("DOMContentLoaded", renderTopbar);
