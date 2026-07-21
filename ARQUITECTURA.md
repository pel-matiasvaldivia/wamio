# Arquitectura de Wamio (SaaS multi-tenant)

Documento vivo de hacia dónde va el producto. Objetivo: **una sola plataforma
en `wamio.pymesenlinea.com.ar` donde cada comercio hace login y gestiona sus
ventas por WhatsApp**, sin instalar ni configurar nada. Toda la infra la maneja
un único operador (vos) en un VPS.

---

## 1. Idea central

- **Un solo despliegue** (el que ya tenés) que atiende a **muchos comercios**.
- Cada comercio es un **"tenant"** (fila en la tabla `comercios`).
- Todos los datos de negocio llevan `comercio_id`; cada comercio **solo ve lo
  suyo**. El aislamiento lo hace el backend, no el cliente.
- Cada comercio conecta **su propio WhatsApp** (una instancia de Evolution por
  comercio) y **cobra en su propia cuenta de Mercado Pago** (token por comercio).
- El comercio interactúa con **una web simple** (login → panel). Nunca ve
  Directus crudo, ni n8n, ni el `.env`, ni la terminal.

---

## 2. Componentes y su rol en el modelo SaaS

| Pieza          | Rol en el SaaS                                                        | ¿Lo ve el comercio? |
|----------------|----------------------------------------------------------------------|:-------------------:|
| **Web app**    | El producto: login, panel de productos/turnos/pedidos, conectar WhatsApp | ✅ Sí (es TODO lo que ve) |
| **Directus**   | Backend headless: auth (usuarios/JWT), API de datos, **aislamiento por comercio** vía políticas, storage de imágenes. Además, consola del **operador** para ver todos los comercios | ❌ (solo el operador) |
| **Postgres**   | Datos de todos los comercios, separados por `comercio_id`            | ❌                  |
| **Evolution API** | Gateway de WhatsApp con **una instancia por comercio**            | ❌ (solo el QR, embebido en la web) |
| **n8n**        | Automatización **tenant-aware**: cada mensaje se resuelve con la config del comercio que corresponde | ❌ |
| **Redis**      | Caché/colas                                                          | ❌                  |
| **Landing**    | Marketing en la raíz + router del dominio                            | ✅ (visitantes)     |

### Por qué Directus como backend (y no armar auth desde cero)

Directus nos da gratis: usuarios + login (JWT), API REST/GraphQL sobre las
tablas, **políticas de acceso por fila** (cada usuario ve solo su `comercio_id`),
storage de imágenes de productos, y una consola de administración para el
operador. Construimos **una web propia simple encima** de su API; el comercio
usa esa web, no Directus.

---

## 3. Aislamiento multi-tenant (cómo cada comercio ve solo lo suyo)

1. Tabla `comercios` (el tenant). Cada usuario de Directus se vincula a un
   comercio (campo `comercio` en `directus_users`).
2. Toda tabla de negocio tiene `comercio_id`.
3. Una **Access Policy** de Directus filtra cada colección por
   `comercio_id == $CURRENT_USER.comercio`. El comercio nunca puede leer ni
   escribir filas de otro, aunque manipule la API.
4. El operador (vos) tiene rol admin y ve todo.

---

## 4. Recorridos

### Alta de un comercio (onboarding)
```
1. El comercio entra a wamio.../ y se registra (o vos lo das de alta).
2. Se crea su fila en `comercios` + su usuario en Directus vinculado a él.
3. En el panel, "Conectar WhatsApp": la web crea su instancia en Evolution y
   muestra el QR. El comercio lo escanea con su teléfono.
4. Carga su catálogo (productos/servicios/horarios) desde el panel simple.
5. (Opcional) Pega su token de Mercado Pago para cobrar.
   → Listo, ya vende por WhatsApp.
```

### Mensaje entrante (runtime, tenant-aware)
```
Cliente final -> WhatsApp del comercio -> Evolution (instancia del comercio)
   -> webhook a n8n con el nombre de la instancia
   -> n8n resuelve comercio_id a partir de la instancia
   -> procesa con el catálogo/horarios/token de ESE comercio
   -> responde por WhatsApp / agenda turno / genera link de pago
```

---

## 5. Roadmap por fases

| Fase | Qué | Estado |
|------|-----|--------|
| **0** | **Modelo de datos multi-tenant** (`comercios` + `comercio_id` en todo, config por comercio) | 🚧 En curso |
| **1** | **Panel web simple del comercio** (login + productos/servicios/turnos/pedidos) sobre la API de Directus, con aislamiento por comercio | ⏳ |
| **2** | **WhatsApp multi-instancia + onboarding**: crear instancia y mostrar QR desde la web | ⏳ |
| **3** | **Flujos n8n tenant-aware**: los 3 flujos parametrizados por comercio | ⏳ |
| **4** | **Registro de comercios + planes/billing** | ⏳ |

Cada fase deja algo usable. Empezamos por la 0 porque **todo lo demás depende
de que los datos estén separados por comercio**.

---

## 6. Decisiones técnicas tomadas

- **Multi-tenancy:** tablas compartidas con `comercio_id` (no una base por
  comercio). Es lo más simple de operar y escalar para este tamaño.
- **Backend:** Directus headless (auth + API + políticas + storage). No se
  reinventa autenticación.
- **Frontend del comercio:** web propia y simple (no se expone Directus).
- **WhatsApp:** una instancia de Evolution por comercio.
- **Pagos:** un token de Mercado Pago por comercio.
