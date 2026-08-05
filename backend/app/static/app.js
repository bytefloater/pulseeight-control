(() => {
  "use strict";

  const state = {
    ports: [],
    inputDetails: {},
    outputDetails: {},
    system: null,
    updates: [],
    status: { configured: false, connected: false, host: null, port: 80, error: null },
  };

  const STATUS_CLASS = { 0: "ok", 1: "no-signal", 2: "warning", 3: "no-signal", 4: "not-present" };
  const STATUS_LABEL = {
    0: "OK",
    1: "Module fault",
    2: "Warning",
    3: "No signal",
    4: "Not present",
  };

  const el = (id) => document.getElementById(id);

  // ---------------- theme ----------------

  const THEME_KEY = "pulseeight-theme";
  // Matches --panel (the topbar's own background) for each theme, so the
  // browser chrome (address bar, status bar) tints the same as the header.
  const THEME_COLOR = { light: "#ffffff", dark: "#18181b" };
  const systemThemeQuery = window.matchMedia("(prefers-color-scheme: light)");

  function effectiveTheme(pref) {
    return pref === "system" ? (systemThemeQuery.matches ? "light" : "dark") : pref;
  }

  function applyTheme(pref) {
    const resolved = effectiveTheme(pref);
    document.documentElement.setAttribute("data-theme", resolved);
    document.querySelectorAll('meta[name="theme-color"]').forEach((meta) => {
      meta.setAttribute("content", THEME_COLOR[resolved]);
    });
  }

  function setupTheme() {
    const stored = localStorage.getItem(THEME_KEY) || "system";
    const select = el("theme-select");
    select.value = stored;
    applyTheme(stored);
    select.addEventListener("change", () => {
      localStorage.setItem(THEME_KEY, select.value);
      applyTheme(select.value);
    });
    systemThemeQuery.addEventListener("change", () => {
      if (select.value === "system") applyTheme("system");
    });
  }

  // ---------------- API ----------------

  async function api(path, options) {
    const res = await fetch(path, {
      headers: { "Content-Type": "application/json" },
      ...options,
    });
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error(body.detail || `Request failed (${res.status})`);
    }
    return res.status === 204 ? null : res.json();
  }

  async function setRoute(inputBay, outputBay) {
    await api("/api/route", { method: "POST", body: JSON.stringify({ input_bay: inputBay, output_bay: outputBay }) });
  }

  // ---------------- WebSocket ----------------

  let ws;
  let wsRetryDelay = 1000;

  function connectWs() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    ws = new WebSocket(`${proto}//${location.host}/ws`);

    ws.addEventListener("open", () => {
      wsRetryDelay = 1000;
    });

    ws.addEventListener("message", (event) => {
      const msg = JSON.parse(event.data);
      handleMessage(msg);
    });

    ws.addEventListener("close", () => {
      setTimeout(connectWs, wsRetryDelay);
      wsRetryDelay = Math.min(wsRetryDelay * 1.5, 15000);
    });

    ws.addEventListener("error", () => ws.close());
  }

  function handleMessage(msg) {
    switch (msg.type) {
      case "ports":
        state.ports = msg.data;
        renderGrid();
        renderPortsTable();
        refreshOpenDrawer();
        break;
      case "details":
        state.inputDetails = msg.data.inputs;
        state.outputDetails = msg.data.outputs;
        renderPortsTable();
        refreshOpenDrawer();
        break;
      case "system":
        state.system = msg.data;
        renderSystem();
        break;
      case "updates":
        state.updates = msg.data;
        renderUpdates();
        break;
      case "status":
        state.status = msg.data;
        renderStatus();
        break;
    }
  }

  // ---------------- rendering: status / topbar ----------------

  function renderStatus() {
    const s = state.status;
    const indicator = el("conn-indicator");
    const text = el("conn-text");
    indicator.classList.remove("connected", "disconnected", "error");

    if (!s.configured) {
      indicator.classList.add("disconnected");
      text.textContent = "Not configured";
    } else if (s.connected) {
      indicator.classList.add("connected");
      text.textContent = `Connected (${s.host})`;
    } else if (s.error) {
      indicator.classList.add("error");
      text.textContent = "Connection error";
    } else {
      indicator.classList.add("disconnected");
      text.textContent = `Connecting (${s.host})`;
    }

    renderConnectionModal(s);
  }

  function renderConnectionModal(s) {
    const modal = el("connection-modal");
    modal.classList.toggle("hidden", s.connected);
    if (s.connected) return;

    const retryBtn = el("connection-modal-retry");
    const errorElm = el("connection-modal-error");

    if (!s.configured) {
      el("connection-modal-title").textContent = "Matrix Not Configured";
      el("connection-modal-message").innerHTML =
        'Add <code>host</code> to <code>backend/config.json</code> (see <code>config.example.json</code>) and restart the server.';
      retryBtn.classList.add("hidden");
      errorElm.classList.add("hidden");
    } else {
      el("connection-modal-title").textContent = "Matrix Not Connected";
      el("connection-modal-message").textContent = `Can't reach the matrix at ${s.host}:${s.port}. Check it's powered on and reachable on the network.`;
      retryBtn.classList.remove("hidden");
      if (s.error) {
        errorElm.textContent = s.error;
        errorElm.classList.remove("hidden");
      } else {
        errorElm.classList.add("hidden");
      }
    }
  }

  async function retryConnection() {
    const retryBtn = el("connection-modal-retry");
    retryBtn.disabled = true;
    retryBtn.textContent = "Retrying…";
    try {
      await api("/api/reconnect", { method: "POST" });
    } catch (err) {
      /* status message will reflect the outcome once it arrives */
    } finally {
      retryBtn.disabled = false;
      retryBtn.textContent = "Retry Now";
    }
  }

  function renderUpdates() {
    const badge = el("updates-badge");
    if (state.updates.length > 0) {
      badge.textContent = `${state.updates.length} firmware update${state.updates.length > 1 ? "s" : ""} available`;
      badge.classList.remove("hidden");
    } else {
      badge.classList.add("hidden");
    }

    const list = el("updates-list");
    if (state.updates.length === 0) {
      list.innerHTML = "No updates detected.";
      return;
    }
    list.innerHTML = "";
    for (const u of state.updates) {
      const k = document.createElement("div");
      k.className = "k";
      k.textContent = `Output ${u.bay} – ${u.name}`;
      const v = document.createElement("div");
      v.className = "v";
      v.innerHTML = `Current: ${u.firmware_version ?? "unknown"} <span class="badge update">update available</span>`;
      list.append(k, v);
    }
  }

  // ---------------- rendering: routing grid ----------------

  function statusDot(status) {
    const cls = STATUS_CLASS[status] ?? "not-present";
    return `<span class="status-dot ${cls}" title="${STATUS_LABEL[status] ?? ""}"></span>`;
  }

  function setStatusDot(dotElm, status) {
    dotElm.className = `status-dot ${STATUS_CLASS[status] ?? "not-present"}`;
    dotElm.title = STATUS_LABEL[status] ?? "";
  }

  // The grid is rebuilt from scratch only when the set of input/output bays
  // changes. Routine polling just updates classes/text on existing nodes, so
  // a click landing mid-poll never grabs a node that's about to be replaced.
  let gridSignature = null;
  const gridCells = new Map(); // "inputBay:outputBay" -> cell button
  const gridHeaderDots = new Map(); // "Input:bay" / "Output:bay" -> dot span
  const gridHeaderNames = new Map(); // "Input:bay" / "Output:bay" -> name span
  const gridColCells = new Map(); // inputBay -> cell[]
  const gridRowCells = new Map(); // outputBay -> cell[]
  const gridColHeaderEl = new Map(); // inputBay -> .col-header element
  const gridRowHeaderEl = new Map(); // outputBay -> .row-header element

  function renderGrid() {
    const inputs = state.ports.filter((p) => p.mode === "Input").sort((a, b) => a.bay - b.bay);
    const outputs = state.ports.filter((p) => p.mode === "Output").sort((a, b) => a.bay - b.bay);
    const grid = el("grid");

    if (inputs.length === 0 && outputs.length === 0) {
      grid.innerHTML = "";
      gridCells.clear();
      gridHeaderDots.clear();
      gridHeaderNames.clear();
      gridSignature = null;
      return;
    }

    const sig = inputs.map((p) => p.bay).join(",") + "|" + outputs.map((p) => p.bay).join(",");
    if (sig !== gridSignature) {
      buildGrid(inputs, outputs);
      gridSignature = sig;
    }

    inputs.forEach((input) => {
      setStatusDot(gridHeaderDots.get(`Input:${input.bay}`), input.status);
      gridHeaderNames.get(`Input:${input.bay}`).textContent = input.name;
    });
    outputs.forEach((output) => {
      setStatusDot(gridHeaderDots.get(`Output:${output.bay}`), output.status);
      gridHeaderNames.get(`Output:${output.bay}`).textContent = output.name;
      inputs.forEach((input) => {
        const cell = gridCells.get(`${input.bay}:${output.bay}`);
        cell.classList.toggle("active", output.receive_from === input.bay);
        cell.title = `${input.name} → ${output.name}`;
      });
    });
  }

  function buildGrid(inputs, outputs) {
    const grid = el("grid");
    grid.innerHTML = "";
    gridCells.clear();
    gridHeaderDots.clear();
    gridHeaderNames.clear();
    gridColCells.clear();
    gridRowCells.clear();
    gridColHeaderEl.clear();
    gridRowHeaderEl.clear();

    grid.style.gridTemplateColumns = `160px repeat(${inputs.length}, 32px)`;
    grid.style.gridTemplateRows = `130px repeat(${outputs.length}, 32px)`;

    const corner = document.createElement("div");
    corner.className = "grid-corner";
    grid.appendChild(corner);

    inputs.forEach((input) => {
      const header = document.createElement("div");
      header.className = "col-header";
      const label = document.createElement("div");
      label.className = "col-header-label";
      label.dataset.bay = input.bay;
      const dot = document.createElement("span");
      dot.className = "status-dot";
      const name = document.createElement("span");
      name.textContent = input.name;
      label.append(dot, name);
      label.addEventListener("click", () => openDrawer("Input", input.bay));
      header.appendChild(label);
      grid.appendChild(header);
      gridHeaderDots.set(`Input:${input.bay}`, dot);
      gridHeaderNames.set(`Input:${input.bay}`, name);
      gridColHeaderEl.set(input.bay, header);
      gridColCells.set(input.bay, []);
    });

    outputs.forEach((output) => {
      const rowHeader = document.createElement("div");
      rowHeader.className = "row-header";
      const label = document.createElement("div");
      label.className = "row-header-label";
      label.dataset.bay = output.bay;
      const name = document.createElement("span");
      name.textContent = output.name;
      const dot = document.createElement("span");
      dot.className = "status-dot";
      label.append(name, dot);
      label.addEventListener("click", () => openDrawer("Output", output.bay));
      rowHeader.appendChild(label);
      grid.appendChild(rowHeader);
      gridHeaderDots.set(`Output:${output.bay}`, dot);
      gridHeaderNames.set(`Output:${output.bay}`, name);
      gridRowHeaderEl.set(output.bay, rowHeader);
      gridRowCells.set(output.bay, []);

      inputs.forEach((input) => {
        const cell = document.createElement("button");
        cell.className = "cell";
        cell.dataset.inputBay = input.bay;
        cell.dataset.outputBay = output.bay;
        cell.innerHTML = '<span class="cell-dot"></span>';
        cell.addEventListener("click", () => onCellClick(input.bay, output.bay, cell));
        grid.appendChild(cell);
        gridCells.set(`${input.bay}:${output.bay}`, cell);
        gridColCells.get(input.bay).push(cell);
        gridRowCells.get(output.bay).push(cell);
      });
    });
  }

  // ---------------- grid row/column hover highlight ----------------

  let hoveredCol = null;
  let hoveredRow = null;

  function setColHover(bay, on) {
    const header = gridColHeaderEl.get(bay);
    if (header) header.classList.toggle("col-hover", on);
    (gridColCells.get(bay) || []).forEach((c) => c.classList.toggle("col-hover", on));
  }

  function setRowHover(bay, on) {
    const header = gridRowHeaderEl.get(bay);
    if (header) header.classList.toggle("row-hover", on);
    (gridRowCells.get(bay) || []).forEach((c) => c.classList.toggle("row-hover", on));
  }

  function clearGridHover() {
    if (hoveredCol !== null) setColHover(hoveredCol, false);
    if (hoveredRow !== null) setRowHover(hoveredRow, false);
    hoveredCol = null;
    hoveredRow = null;
  }

  function hoverAxes(inputBay, outputBay) {
    if (inputBay !== hoveredCol) {
      if (hoveredCol !== null) setColHover(hoveredCol, false);
      hoveredCol = inputBay;
      if (hoveredCol !== null) setColHover(hoveredCol, true);
    }
    if (outputBay !== hoveredRow) {
      if (hoveredRow !== null) setRowHover(hoveredRow, false);
      hoveredRow = outputBay;
      if (hoveredRow !== null) setRowHover(hoveredRow, true);
    }
  }

  function setupGridHover() {
    const grid = el("grid");
    grid.addEventListener("mouseover", (e) => {
      const cell = e.target.closest(".cell");
      if (cell) {
        hoverAxes(Number(cell.dataset.inputBay), Number(cell.dataset.outputBay));
        return;
      }
      const colLabel = e.target.closest(".col-header-label");
      if (colLabel) {
        hoverAxes(Number(colLabel.dataset.bay), null);
        return;
      }
      const rowLabel = e.target.closest(".row-header-label");
      if (rowLabel) hoverAxes(null, Number(rowLabel.dataset.bay));
    });
    grid.addEventListener("mouseleave", clearGridHover);
  }

  async function onCellClick(inputBay, outputBay, cellElm) {
    cellElm.classList.add("pending");
    try {
      await setRoute(inputBay, outputBay);
    } catch (err) {
      alert(`Failed to set route: ${err.message}`);
    } finally {
      cellElm.classList.remove("pending");
    }
  }

  // ---------------- rendering: hardware tab ----------------

  function kv(pairs) {
    return pairs
      .filter(([, v]) => v !== undefined && v !== null && v !== "")
      .map(([k, v]) => `<div class="k">${escapeHtml(k)}</div><div class="v">${v}</div>`)
      .join("");
  }

  function renderSystem() {
    if (!state.system) return;
    const d = state.system.details;
    el("system-details").innerHTML = kv([
      ["Model", d.model],
      ["Firmware version", d.version],
      ["Serial", d.serial],
      ["MAC address", d.mac],
      ["VID", d.vid],
      ["Board revision", d.board_rev],
      ["Locale", d.locale],
      ["Status", d.status_message],
    ]);

    const f = state.system.features;
    el("system-features").innerHTML = kv([
      ["HDBaseT", f.hdbaset ? "Yes" : "No"],
      ["HDBaseT upgrade capable", f.hdbt_upgrade ? "Yes" : "No"],
      ["CEC", f.cec ? "Yes" : "No"],
      ["CEC switching", f.cec_switching ? "Yes" : "No"],
      ["PoE / PDU", f.pdu ? "Yes" : "No"],
      ["Sky control", f.sky ? "Yes" : "No"],
      ["MX Remote", f.mx_remote ? "Yes" : "No"],
      ["Audio routing", f.audio && f.audio.routing ? "Yes" : "No"],
      ["Video scrambling", f.video && f.video.scrambling ? "Yes" : "No"],
      ["Update interval", formatMs(f.upd_interval)],
    ]);

    renderBacklightCard(f);
    renderStatusLedToggle(f);
  }

  let backlightSaving = false;

  function renderBacklightCard(f) {
    const card = el("frontpanel-card");
    if (!f.backlight_led) {
      card.classList.add("hidden");
      return;
    }
    card.classList.remove("hidden");
    // Skip while a click's save is in flight so a poll landing mid-request
    // doesn't flicker the selection back and forth.
    if (backlightSaving) return;
    setBacklightActive(f.backlight_led);
  }

  function setBacklightActive(level) {
    document.querySelectorAll("#backlight-segmented .segmented-option").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.value === level);
    });
  }

  async function onBacklightOptionClick(level) {
    if (backlightSaving) return;
    const errorElm = el("backlight-error");
    errorElm.classList.add("hidden");
    setBacklightActive(level);
    backlightSaving = true;
    document.querySelectorAll("#backlight-segmented .segmented-option").forEach((btn) => (btn.disabled = true));
    try {
      await api("/api/system/backlight", { method: "POST", body: JSON.stringify({ level }) });
    } catch (err) {
      errorElm.textContent = err.message;
      errorElm.classList.remove("hidden");
    } finally {
      backlightSaving = false;
      document.querySelectorAll("#backlight-segmented .segmented-option").forEach((btn) => (btn.disabled = false));
    }
  }

  let statusLedSaving = false;

  function renderStatusLedToggle(f) {
    const label = el("statusled-label");
    const row = el("statusled-row");
    if (!f.status_led) {
      label.classList.add("hidden");
      row.classList.add("hidden");
      return;
    }
    label.classList.remove("hidden");
    row.classList.remove("hidden");
    // Skip while a save is in flight so a poll landing mid-request doesn't
    // flip the switch back and forth.
    if (statusLedSaving) return;
    el("statusled-toggle").checked = f.status_led === "on";
  }

  async function onStatusLedToggleChange() {
    const toggle = el("statusled-toggle");
    const errorElm = el("statusled-error");
    const on = toggle.checked;
    errorElm.classList.add("hidden");
    statusLedSaving = true;
    toggle.disabled = true;
    try {
      await api("/api/system/status-led", { method: "POST", body: JSON.stringify({ on }) });
    } catch (err) {
      toggle.checked = !on;
      errorElm.textContent = err.message;
      errorElm.classList.remove("hidden");
    } finally {
      statusLedSaving = false;
      toggle.disabled = false;
    }
  }

  function inputName(bay) {
    const input = state.ports.find((p) => p.mode === "Input" && p.bay === bay);
    return input ? input.name : `Input ${bay}`;
  }

  function renderPortsTable() {
    const wrap = el("ports-table-wrap");
    if (state.ports.length === 0) {
      wrap.innerHTML = "No ports discovered yet.";
      return;
    }
    const sorted = [...state.ports].sort((a, b) => (a.mode === b.mode ? a.bay - b.bay : a.mode.localeCompare(b.mode)));
    const rows = sorted
      .map((p) => {
        const outDetails = p.mode === "Output" ? state.outputDetails[p.bay] : null;
        const updateBadge =
          outDetails && outDetails.firmware_version_available ? '<span class="badge update">update</span>' : "";
        const routedFrom =
          p.mode === "Output" && p.receive_from !== null && p.receive_from !== undefined
            ? escapeHtml(inputName(p.receive_from))
            : "—";
        return `<tr data-mode="${p.mode}" data-bay="${p.bay}">
          <td>${p.mode}</td>
          <td>${p.bay}</td>
          <td>${escapeHtml(p.name)}</td>
          <td>${escapeHtml(p.type)}</td>
          <td>${statusDot(p.status)} ${STATUS_LABEL[p.status] ?? ""}</td>
          <td>${routedFrom}</td>
          <td>${updateBadge}</td>
        </tr>`;
      })
      .join("");

    wrap.innerHTML = `<table class="ports-table">
      <thead><tr><th>Mode</th><th>Bay</th><th>Name</th><th>Type</th><th>Status</th><th>Source</th><th></th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;

    wrap.querySelectorAll("tbody tr").forEach((tr) => {
      tr.addEventListener("click", () => openDrawer(tr.dataset.mode, Number(tr.dataset.bay)));
    });
  }

  // ---------------- detail drawer ----------------

  const PORT_NAME_MAX_LENGTH = 13;
  let openDrawerRef = null;

  function openDrawer(mode, bay) {
    openDrawerRef = { mode, bay };
    el("detail-drawer").classList.add("open");
    el("drawer-backdrop").classList.remove("hidden");
    buildRenameSection(mode, bay);
    renderDrawer();
  }

  function closeDrawer() {
    openDrawerRef = null;
    el("detail-drawer").classList.remove("open");
    el("drawer-backdrop").classList.add("hidden");
  }

  function refreshOpenDrawer() {
    // Only the read-only details refresh live; the rename form is left
    // alone so a poll landing mid-edit doesn't clobber what's being typed.
    if (openDrawerRef) renderDrawer();
  }

  function buildRenameSection(mode, bay) {
    const port = state.ports.find((p) => p.mode === mode && p.bay === bay);
    const container = el("drawer-rename");
    container.innerHTML = `
      <div class="rename-row">
        <input type="text" id="drawer-rename-input" maxlength="${PORT_NAME_MAX_LENGTH}" value="${escapeHtml(port ? port.name : "")}" />
        <button type="button" id="drawer-rename-save" class="rename-save-btn">Save</button>
      </div>
      ${
        mode === "Input"
          ? '<div class="rename-row edid-row"><select id="drawer-edid-select" class="rename-row-select"><option>Loading EDID profiles…</option></select></div>'
          : ""
      }
      <p id="drawer-rename-error" class="form-error hidden"></p>
    `;
    el("drawer-rename-save").addEventListener("click", () => submitPortEdit(mode, bay));
    el("drawer-rename-input").addEventListener("keydown", (e) => {
      if (e.key === "Enter") submitPortEdit(mode, bay);
    });
    if (mode === "Input") populateEdidSelect(bay);
  }

  async function populateEdidSelect(bay) {
    const select = el("drawer-edid-select");
    if (!select) return;
    try {
      const profiles = await api("/api/edid-profiles");
      const details = state.inputDetails[bay];
      const current = details ? details.edid_profile : null;
      select.innerHTML = profiles.map((p) => `<option value="${p.id}">${escapeHtml(p.name)}</option>`).join("");
      if (current !== null && current !== undefined) {
        if (!profiles.some((p) => p.id === current)) {
          select.insertAdjacentHTML("beforeend", `<option value="${current}">Custom Profile (${current})</option>`);
        }
        select.value = String(current);
      }
    } catch (err) {
      select.innerHTML = `<option>Failed to load profiles</option>`;
    }
  }

  async function submitPortEdit(mode, bay) {
    const input = el("drawer-rename-input");
    const saveBtn = el("drawer-rename-save");
    const errorElm = el("drawer-rename-error");
    const edidSelect = el("drawer-edid-select");
    const name = input.value.trim();

    errorElm.classList.add("hidden");
    if (!name) {
      errorElm.textContent = "Name can't be empty.";
      errorElm.classList.remove("hidden");
      return;
    }

    saveBtn.disabled = true;
    saveBtn.textContent = "Saving…";
    try {
      await api("/api/ports/rename", { method: "POST", body: JSON.stringify({ mode, bay, name }) });
      input.value = name;
      if (mode === "Input" && edidSelect && edidSelect.value) {
        await api("/api/ports/edid", { method: "POST", body: JSON.stringify({ bay, profile: Number(edidSelect.value) }) });
      }
    } catch (err) {
      errorElm.textContent = err.message;
      errorElm.classList.remove("hidden");
    } finally {
      saveBtn.disabled = false;
      saveBtn.textContent = "Save";
    }
  }

  function renderDrawer() {
    if (!openDrawerRef) return;
    const { mode, bay } = openDrawerRef;
    const port = state.ports.find((p) => p.mode === mode && p.bay === bay);
    const details = mode === "Input" ? state.inputDetails[bay] : state.outputDetails[bay];

    el("drawer-title").textContent = port ? `${mode} ${bay} – ${port.name}` : `${mode} ${bay}`;

    const statusValue = details ? details.status : port ? port.status : null;
    const rows = [["Status", statusValue !== null ? `${statusDot(statusValue)} ${STATUS_LABEL[statusValue] ?? ""}` : "—"]];
    rows.push(["Type", port ? port.type : "—"]);

    if (details) {
      rows.push(["Has signal", details.has_signal ? "Yes" : "No"]);
      if (details.signal) rows.push(["Signal", details.signal]);
      if (mode === "Input") {
        if (details.hdcp !== undefined && details.hdcp !== null) rows.push(["HDCP", details.hdcp]);
      } else {
        if (details.receive_from !== undefined && details.receive_from !== null) rows.push(["Routed from input", escapeHtml(inputName(details.receive_from))]);
        if (details.link_status) rows.push(["Link status", details.link_status]);
        if (details.estimated_cable_length) rows.push(["Cable length (est.)", `${details.estimated_cable_length} m`]);
        if (details.vendor) rows.push(["Sink vendor", details.vendor]);
        if (details.monitor_name) rows.push(["Sink model", details.monitor_name]);
        if (details.firmware_version) {
          rows.push([
            "Firmware version",
            `${details.firmware_version} ${details.firmware_version_available ? '<span class="badge update">update available</span>' : '<span class="badge ok">up to date</span>'}`,
          ]);
        }
        if (details.link_quality) {
          const lq = details.link_quality;
          rows.push(["TMDS", lq.tmds]);
          rows.push(["Total BER", lq.total_ber]);
        }
      }
    } else {
      rows.push(["Details", "Loading…"]);
    }

    el("drawer-kv").innerHTML = kv(rows);
  }

  // ---------------- misc ----------------

  function escapeHtml(str) {
    return String(str).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  function formatMs(ms) {
    const s = ms / 1000;
    if (s < 60) return `${s}s`;
    const m = s / 60;
    if (m < 60) return `${Math.round(m * 10) / 10}m`;
    return `${Math.round((m / 60) * 10) / 10}h`;
  }

  function setupTabs() {
    document.querySelectorAll(".tab-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".tab-btn").forEach((b) => b.classList.remove("active"));
        document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
        btn.classList.add("active");
        el(`tab-${btn.dataset.tab}`).classList.add("active");
      });
    });
  }

  function setupUi() {
    setupTabs();
    el("drawer-close").addEventListener("click", closeDrawer);
    el("drawer-backdrop").addEventListener("click", closeDrawer);
    el("updates-badge").addEventListener("click", () => {
      document.querySelector('.tab-btn[data-tab="hardware"]').click();
      el("updates-card").scrollIntoView({ behavior: "smooth" });
    });
    el("connection-modal-retry").addEventListener("click", retryConnection);
    document.querySelectorAll("#backlight-segmented .segmented-option").forEach((btn) => {
      btn.addEventListener("click", () => onBacklightOptionClick(btn.dataset.value));
    });
    el("statusled-toggle").addEventListener("change", onStatusLedToggleChange);
    setupGridHover();
    setupTheme();
  }

  function registerServiceWorker() {
    if (!("serviceWorker" in navigator)) return;
    navigator.serviceWorker.register("/sw.js").catch(() => {
      /* PWA install just won't be offered; app still works fine */
    });
  }

  async function bootstrap() {
    setupUi();
    renderConnectionModal(state.status);
    try {
      state.status = await api("/api/status");
      renderStatus();
    } catch (err) {
      /* ignore, ws will catch us up */
    }
    if (state.status.configured) {
      try {
        state.ports = await api("/api/ports");
        renderGrid();
        renderPortsTable();
      } catch (err) {
        /* ignore */
      }
      try {
        state.system = await api("/api/system");
        renderSystem();
      } catch (err) {
        /* not fetched yet server-side, or matrix unreachable; the WS snapshot will catch us up */
      }
    }
    connectWs();
    registerServiceWorker();
  }

  bootstrap();
})();
