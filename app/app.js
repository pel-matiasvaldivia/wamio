/* Wamio — panel del comercio.
 * SPA liviana (sin build) que consume la API de Directus servida en el mismo
 * dominio. El aislamiento por comercio lo aplica Directus (políticas por fila);
 * acá solo mandamos comercio_id del usuario logueado al crear registros. */

const API = "";                       // mismo origen: /auth/*, /items/*, /users/me
const $ = (s, r = document) => r.querySelector(s);

const state = { token: null, refresh: null, me: null, view: "inicio" };

/* ---------- Auth / storage ---------- */
const store = {
  save: (a) => localStorage.setItem("wamio_auth", JSON.stringify(a)),
  load: () => { try { return JSON.parse(localStorage.getItem("wamio_auth")); } catch { return null; } },
  clear: () => localStorage.removeItem("wamio_auth"),
};

async function apiFetch(path, opts = {}) {
  opts.headers = Object.assign({ "Content-Type": "application/json" }, opts.headers || {});
  if (state.token) opts.headers.Authorization = "Bearer " + state.token;
  let res = await fetch(API + path, opts);
  if (res.status === 401 && state.refresh) {
    if (await refreshToken()) {
      opts.headers.Authorization = "Bearer " + state.token;
      res = await fetch(API + path, opts);
    }
  }
  return res;
}

async function login(email, password) {
  const res = await fetch(API + "/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password, mode: "json" }),
  });
  if (!res.ok) throw new Error("Email o contraseña incorrectos.");
  const { data } = await res.json();
  state.token = data.access_token;
  state.refresh = data.refresh_token;
  store.save({ token: state.token, refresh: state.refresh });
}

async function refreshToken() {
  try {
    const res = await fetch(API + "/auth/refresh", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refresh_token: state.refresh, mode: "json" }),
    });
    if (!res.ok) return false;
    const { data } = await res.json();
    state.token = data.access_token;
    state.refresh = data.refresh_token;
    store.save({ token: state.token, refresh: state.refresh });
    return true;
  } catch { return false; }
}

async function loadMe() {
  const res = await apiFetch("/users/me?fields=id,first_name,email,comercio.id,comercio.nombre");
  if (!res.ok) return false;
  const { data } = await res.json();
  state.me = data;
  return true;
}

function logout() {
  store.clear();
  state.token = state.refresh = state.me = null;
  render();
}

/* ---------- Helpers de datos (Directus items) ---------- */
const comercioId = () => state.me && state.me.comercio && state.me.comercio.id;

async function list(collection, query = "") {
  const res = await apiFetch(`/items/${collection}?${query}`);
  if (!res.ok) return [];
  return (await res.json()).data || [];
}
async function count(collection, extra = "") {
  const res = await apiFetch(`/items/${collection}?aggregate[count]=id${extra ? "&" + extra : ""}`);
  if (!res.ok) return 0;
  const d = (await res.json()).data;
  return d && d[0] ? Number(d[0].count) : 0;
}
async function createItem(collection, body) {
  body.comercio_id = comercioId();
  return apiFetch(`/items/${collection}`, { method: "POST", body: JSON.stringify(body) });
}
async function updateItem(collection, id, body) {
  return apiFetch(`/items/${collection}/${id}`, { method: "PATCH", body: JSON.stringify(body) });
}
async function deleteItem(collection, id) {
  return apiFetch(`/items/${collection}/${id}`, { method: "DELETE" });
}

const money = (n) => "$" + Number(n || 0).toLocaleString("es-AR", { minimumFractionDigits: 2 });
const fmtDate = (s) => s ? new Date(s).toLocaleString("es-AR", { dateStyle: "medium", timeStyle: "short" }) : "—";
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function toast(msg) {
  const t = document.createElement("div");
  t.className = "toast"; t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 2500);
}

/* ---------- Modal de formulario ---------- */
function openForm(title, fields, values, onSave) {
  $("#modal-title").textContent = title;
  const form = $("#modal-form");
  form.innerHTML = fields.map((f) => {
    const v = values[f.name] != null ? values[f.name] : (f.default != null ? f.default : "");
    if (f.type === "textarea") return `<label>${f.label}<textarea name="${f.name}" rows="3">${esc(v)}</textarea></label>`;
    if (f.type === "select") return `<label>${f.label}<select name="${f.name}">${f.options.map((o) => `<option value="${o.value}" ${String(o.value) === String(v) ? "selected" : ""}>${esc(o.label)}</option>`).join("")}</select></label>`;
    const step = f.type === "number" ? ' step="0.01"' : "";
    return `<label>${f.label}<input name="${f.name}" type="${f.type || "text"}"${step} value="${esc(v)}" ${f.required ? "required" : ""} /></label>`;
  }).join("") + `<div class="modal-actions"><button type="button" class="btn btn--ghost" id="modal-cancel">Cancelar</button><button type="submit" class="btn btn--verde">Guardar</button></div>`;
  $("#modal").hidden = false;
  $("#modal-cancel").onclick = () => ($("#modal").hidden = true);
  form.onsubmit = async (e) => {
    e.preventDefault();
    const body = {};
    fields.forEach((f) => {
      let val = form.elements[f.name].value;
      if (f.type === "number") val = val === "" ? null : Number(val);
      body[f.name] = val;
    });
    try { await onSave(body); $("#modal").hidden = true; }
    catch (err) { toast("No se pudo guardar"); }
  };
}
$("#modal-close").onclick = () => ($("#modal").hidden = true);

/* ---------- Vistas ---------- */
const main = () => $("#main");

async function viewInicio() {
  main().innerHTML = `<div class="page-head"><h1>Hola, ${esc((state.me.comercio && state.me.comercio.nombre) || "tu comercio")} 👋</h1></div><div class="cards" id="stats"><div class="loading">Cargando…</div></div>`;
  const [prod, serv, turnosHoy, pagos] = await Promise.all([
    count("productos"), count("servicios"),
    count("turnos", "filter[estado][_in]=pendiente,confirmado"),
    count("pedidos", "filter[estado_pago][_eq]=pagado"),
  ]);
  $("#stats").innerHTML = `
    <div class="stat"><div class="n">${prod}</div><div class="l">Productos</div></div>
    <div class="stat"><div class="n">${serv}</div><div class="l">Servicios</div></div>
    <div class="stat"><div class="n">${turnosHoy}</div><div class="l">Turnos activos</div></div>
    <div class="stat"><div class="n">${pagos}</div><div class="l">Pedidos pagados</div></div>`;
}

async function viewProductos() {
  main().innerHTML = `<div class="page-head"><h1>Productos</h1><button class="btn btn--verde" id="nuevo">+ Nuevo producto</button></div><div id="tabla" class="loading">Cargando…</div>`;
  const fields = [
    { name: "nombre", label: "Nombre", required: true },
    { name: "precio", label: "Precio", type: "number", required: true },
    { name: "stock", label: "Stock", type: "number", default: 0 },
    { name: "descripcion", label: "Descripción", type: "textarea" },
    { name: "activo", label: "Activo", type: "select", options: [{ value: "true", label: "Sí" }, { value: "false", label: "No" }], default: "true" },
  ];
  const norm = (b) => ({ ...b, activo: b.activo === "true" || b.activo === true });
  const reload = async () => {
    const items = await list("productos", "fields=*&sort=-id&limit=200");
    $("#tabla").innerHTML = items.length ? `<table><thead><tr><th>Nombre</th><th>Precio</th><th>Stock</th><th>Estado</th><th></th></tr></thead><tbody>${items.map((p) => `
      <tr><td>${esc(p.nombre)}</td><td>${money(p.precio)}</td><td>${p.stock}</td>
      <td><span class="tag ${p.activo ? "ok" : "bad"}">${p.activo ? "Activo" : "Inactivo"}</span></td>
      <td class="row-actions"><button class="btn btn--ghost btn--sm" data-edit="${p.id}">✏️</button><button class="btn btn--ghost btn--sm" data-del="${p.id}">🗑️</button></td></tr>`).join("")}</tbody></table>`
      : `<div class="empty">Todavía no cargaste productos. Tocá “+ Nuevo producto”.</div>`;
    $("#tabla").querySelectorAll("[data-edit]").forEach((b) => b.onclick = () => {
      const p = items.find((x) => x.id == b.dataset.edit);
      openForm("Editar producto", fields, { ...p, activo: String(p.activo) }, async (body) => { await updateItem("productos", p.id, norm(body)); toast("Guardado"); reload(); });
    });
    $("#tabla").querySelectorAll("[data-del]").forEach((b) => b.onclick = async () => {
      if (!confirm("¿Borrar este producto?")) return;
      await deleteItem("productos", b.dataset.del); toast("Borrado"); reload();
    });
  };
  $("#nuevo").onclick = () => openForm("Nuevo producto", fields, {}, async (body) => { await createItem("productos", norm(body)); toast("Creado"); reload(); });
  reload();
}

async function viewServicios() {
  main().innerHTML = `<div class="page-head"><h1>Servicios</h1><button class="btn btn--verde" id="nuevo">+ Nuevo servicio</button></div><div id="tabla" class="loading">Cargando…</div>`;
  const fields = [
    { name: "nombre", label: "Nombre", required: true },
    { name: "precio", label: "Precio", type: "number", required: true },
    { name: "duracion_minutos", label: "Duración (min)", type: "number", default: 30 },
    { name: "descripcion", label: "Descripción", type: "textarea" },
    { name: "activo", label: "Activo", type: "select", options: [{ value: "true", label: "Sí" }, { value: "false", label: "No" }], default: "true" },
  ];
  const norm = (b) => ({ ...b, activo: b.activo === "true" || b.activo === true });
  const reload = async () => {
    const items = await list("servicios", "fields=*&sort=-id&limit=200");
    $("#tabla").innerHTML = items.length ? `<table><thead><tr><th>Nombre</th><th>Precio</th><th>Duración</th><th>Estado</th><th></th></tr></thead><tbody>${items.map((s) => `
      <tr><td>${esc(s.nombre)}</td><td>${money(s.precio)}</td><td>${s.duracion_minutos} min</td>
      <td><span class="tag ${s.activo ? "ok" : "bad"}">${s.activo ? "Activo" : "Inactivo"}</span></td>
      <td class="row-actions"><button class="btn btn--ghost btn--sm" data-edit="${s.id}">✏️</button><button class="btn btn--ghost btn--sm" data-del="${s.id}">🗑️</button></td></tr>`).join("")}</tbody></table>`
      : `<div class="empty">Todavía no cargaste servicios. Tocá “+ Nuevo servicio”.</div>`;
    $("#tabla").querySelectorAll("[data-edit]").forEach((b) => b.onclick = () => {
      const s = items.find((x) => x.id == b.dataset.edit);
      openForm("Editar servicio", fields, { ...s, activo: String(s.activo) }, async (body) => { await updateItem("servicios", s.id, norm(body)); toast("Guardado"); reload(); });
    });
    $("#tabla").querySelectorAll("[data-del]").forEach((b) => b.onclick = async () => {
      if (!confirm("¿Borrar este servicio?")) return;
      await deleteItem("servicios", b.dataset.del); toast("Borrado"); reload();
    });
  };
  $("#nuevo").onclick = () => openForm("Nuevo servicio", fields, {}, async (body) => { await createItem("servicios", norm(body)); toast("Creado"); reload(); });
  reload();
}

const ESTADO_TAG = { pendiente: "warn", confirmado: "ok", cancelado: "bad", completado: "info", pagado: "ok", rechazado: "bad", reembolsado: "info" };

async function viewTurnos() {
  main().innerHTML = `<div class="page-head"><h1>Turnos</h1></div><div id="tabla" class="loading">Cargando…</div>`;
  const items = await list("turnos", "fields=*,cliente_id.nombre,cliente_id.telefono,servicio_id.nombre&sort=-fecha_hora&limit=200");
  const estados = ["pendiente", "confirmado", "completado", "cancelado"];
  $("#tabla").innerHTML = items.length ? `<table><thead><tr><th>Fecha</th><th>Cliente</th><th>Servicio</th><th>Estado</th></tr></thead><tbody>${items.map((t) => `
    <tr><td>${fmtDate(t.fecha_hora)}</td>
    <td>${esc((t.cliente_id && t.cliente_id.nombre) || (t.cliente_id && t.cliente_id.telefono) || "—")}</td>
    <td>${esc((t.servicio_id && t.servicio_id.nombre) || "—")}</td>
    <td><select data-turno="${t.id}" class="tag">${estados.map((e) => `<option value="${e}" ${e === t.estado ? "selected" : ""}>${e}</option>`).join("")}</select></td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">Todavía no hay turnos. Aparecerán acá cuando tus clientes reserven por WhatsApp.</div>`;
  $("#tabla").querySelectorAll("[data-turno]").forEach((sel) => sel.onchange = async () => {
    await updateItem("turnos", sel.dataset.turno, { estado: sel.value }); toast("Turno actualizado");
  });
}

async function viewPedidos() {
  main().innerHTML = `<div class="page-head"><h1>Pedidos</h1></div><div id="tabla" class="loading">Cargando…</div>`;
  const items = await list("pedidos", "fields=*,cliente_id.nombre,cliente_id.telefono&sort=-id&limit=200");
  $("#tabla").innerHTML = items.length ? `<table><thead><tr><th>#</th><th>Cliente</th><th>Total</th><th>Pago</th><th>Fecha</th></tr></thead><tbody>${items.map((p) => `
    <tr><td>${p.id}</td>
    <td>${esc((p.cliente_id && p.cliente_id.nombre) || (p.cliente_id && p.cliente_id.telefono) || "—")}</td>
    <td>${money(p.total)}</td>
    <td><span class="tag ${ESTADO_TAG[p.estado_pago] || "info"}">${esc(p.estado_pago)}</span></td>
    <td>${fmtDate(p.creado_en)}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">Todavía no hay pedidos.</div>`;
}

const VIEWS = { inicio: viewInicio, productos: viewProductos, servicios: viewServicios, turnos: viewTurnos, pedidos: viewPedidos };

function setView(v) {
  state.view = v;
  document.querySelectorAll(".nav-item").forEach((b) => b.classList.toggle("active", b.dataset.view === v));
  (VIEWS[v] || viewInicio)().catch(() => (main().innerHTML = `<div class="empty">No se pudo cargar. Reintentá.</div>`));
}

/* ---------- Arranque ---------- */
function showLogin(msg) {
  $("#app").hidden = true;
  $("#login").hidden = false;
  const err = $("#login-error");
  if (msg) { err.textContent = msg; err.hidden = false; } else err.hidden = true;
}

async function showApp() {
  $("#login").hidden = true;
  $("#app").hidden = false;
  $("#comercio-nombre").textContent = (state.me.comercio && state.me.comercio.nombre) || state.me.email;
  if (!comercioId()) {
    main().innerHTML = `<div class="empty">Tu usuario todavía no tiene un comercio asignado.<br>Pedile al administrador de Wamio que lo vincule.</div>`;
    document.querySelectorAll(".nav-item").forEach((b) => b.disabled = true);
    return;
  }
  setView("inicio");
}

async function render() {
  const saved = store.load();
  if (saved && saved.token) {
    state.token = saved.token; state.refresh = saved.refresh;
    if (await loadMe()) return showApp();
  }
  showLogin();
}

document.querySelectorAll(".nav-item").forEach((b) => b.onclick = () => setView(b.dataset.view));
$("#logout").onclick = logout;
$("#login-form").onsubmit = async (e) => {
  e.preventDefault();
  try {
    await login($("#email").value.trim(), $("#password").value);
    if (await loadMe()) showApp(); else showLogin("No se pudo cargar tu usuario.");
  } catch (err) { showLogin(err.message || "No se pudo ingresar."); }
};

render();
