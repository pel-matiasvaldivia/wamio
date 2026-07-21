# Guía de uso de Wamio

Manual completo de la plataforma: qué hace cada pieza, cómo se accede a cada
ruta y cuál es el flujo de trabajo de punta a punta —desde que un cliente
escribe por WhatsApp hasta que paga y queda registrado.

> Para instalar/levantar el stack por primera vez, ver **[README.md](README.md)**
> (arranque, imágenes de CI, backups y troubleshooting). Esta guía es sobre
> **cómo se usa** una vez que está corriendo.

---

## 1. Qué es Wamio

Wamio convierte el WhatsApp de un comercio de barrio en un canal de ventas y
reservas automático: responde consultas, muestra el catálogo, agenda turnos y
cobra con Mercado Pago, sin depender de la API oficial de Meta y con todos los
datos en tu propio servidor.

No es una sola aplicación: son varias piezas que trabajan juntas.

| Pieza          | Para qué sirve                                                     | Quién la usa            |
|----------------|-------------------------------------------------------------------|-------------------------|
| **Landing**    | Página pública de presentación + router del dominio               | Visitantes              |
| **Evolution API** | Conecta el número de WhatsApp (escaneo de QR) y envía/recibe mensajes | Vos (una vez, al conectar) |
| **n8n**        | El "cerebro": los flujos que atienden, agendan y cobran            | Vos (armás los flujos)  |
| **Directus**   | Panel para cargar productos, servicios, precios y ver turnos/pedidos | Vos (día a día)         |
| **Postgres**   | Guarda todo (clientes, productos, turnos, pedidos)                 | — (interno)             |
| **Redis**      | Caché y colas de los servicios                                     | — (interno)             |
| **Chatwoot**   | *(opcional)* bandeja para atención humana cuando hace falta        | Vos / tu equipo         |

### Cómo se conectan

```
                    Cliente por WhatsApp
                            │
                            ▼
   ┌─────────────────────────────────────────────┐
   │              Evolution API                   │  ← conecta el número (QR)
   └───────────────────┬─────────────────────────┘
                       │ webhook (mensaje entrante)
                       ▼
   ┌─────────────────────────────────────────────┐
   │                    n8n                       │  ← decide qué responder
   │   (catálogo · turnos · pagos · recordatorios)│
   └───┬─────────────────┬────────────────┬───────┘
       │                 │                │
       ▼                 ▼                ▼
  Postgres (wamio)   Mercado Pago    Evolution API
  productos/turnos   link de pago    (envía respuesta)
       ▲
       │ carga/edición
   ┌───┴───────┐
   │ Directus  │  ← vos administrás el catálogo y ves los turnos/pedidos
   └───────────┘
```

---

## 2. Rutas del sistema

Todo entra por un **único dominio** (`WAMIO_PUBLIC_URL`, por defecto
`https://wamio.pymesenlinea.com.ar`). El contenedor **landing** recibe todo y
reparte cada ruta al servicio que corresponde:

| Ruta        | Va a          | Para qué                                            | Público |
|-------------|---------------|-----------------------------------------------------|:-------:|
| `/`         | Landing       | Presentación del producto (marketing)               | ✅ Sí   |
| `/admin/`   | Directus      | Panel del comercio: catálogo, turnos, pedidos       | 🔒 Login |
| `/n8n/`     | n8n           | Editor de automatizaciones (flujos)                 | 🔒 Login |
| `/api/`     | Evolution API | REST del gateway (para integraciones/monitoreo)     | 🔑 API key |
| `/healthz`  | Landing       | Chequeo de salud del router                         | ✅ Sí   |

**Consola visual de Evolution (Manager, para escanear el QR):** no se publica en
el dominio. Se accede por el puerto del servidor:
`http://IP_DEL_SERVIDOR:8054/manager`. Es de uso ocasional (conectar o reconectar
WhatsApp); si preferís no exponer ese puerto a internet, hacé un túnel SSH:
`ssh -L 8054:localhost:8054 usuario@servidor` y entrá a `http://localhost:8054/manager`.

> Los puertos directos (`5678` n8n, `8055` Directus, `8054` Evolution,
> `3056` Chatwoot, `8060` landing) siguen existiendo para depurar en el
> servidor, pero **en producción se entra por el dominio**, no por los puertos.

### Configuración en Nginx Proxy Manager

Con este diseño, en NPM alcanza con **un solo Proxy Host**:

- **Domain Names:** `wamio.pymesenlinea.com.ar`
- **Scheme:** `http`
- **Forward Hostname / IP:** `wamio_landing` (o la IP del server)
- **Forward Port:** `8080`
- **Websockets Support:** ✅ activado (n8n y Directus lo necesitan)
- **SSL:** certificado Let's Encrypt + "Force SSL"

El router interno (nginx del contenedor landing) ya reenvía `/admin`, `/n8n` y
`/api` a cada servicio con los headers y websockets correctos. No hace falta un
Proxy Host por servicio.

---

## 3. Puesta en marcha (resumen)

Detalle completo en el README. En limpio:

```bash
cp .env.example .env
nano .env
#  - WAMIO_PUBLIC_URL = tu dominio (https://wamio.pymesenlinea.com.ar)
#  - N8N_HOST = tu dominio SIN https:// (wamio.pymesenlinea.com.ar), N8N_PROTOCOL=https
#  - POSTGRES_PASSWORD y REDIS_PASSWORD: SOLO alfanuméricas -> openssl rand -hex 32
#  - resto de claves: openssl rand -hex 32

docker compose pull       # trae las imágenes de CI (GHCR)
docker compose up -d       # levanta todo
docker compose ps          # verificá que estén "healthy"/"running"
```

Verificá que las bases se crearon:

```bash
docker exec wamio_postgres psql -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2)" -lqt | cut -d'|' -f1
#  Deberías ver: evolution, n8n, wamio, chatwoot
```

Entrá a `https://tu-dominio/` → tenés que ver la landing.

---

## 4. Primeros pasos (configuración inicial, una sola vez)

### Paso 1 — Conectar el WhatsApp del comercio

1. Entrá al Manager de Evolution: `http://IP_DEL_SERVIDOR:8054/manager` (o vía
   túnel SSH, ver sección 2). Iniciá sesión con la `EVOLUTION_API_KEY` del `.env`.
2. Creá una **instancia** nueva (ej. nombre `wamio`).
3. Se genera un **QR**: abrí WhatsApp en el teléfono del comercio →
   **Dispositivos vinculados → Vincular un dispositivo** → escaneá el QR.
4. Cuando el estado pase a **connected**, el número ya está integrado.

> El webhook global ya está configurado por el compose para mandar cada mensaje
> entrante a n8n (`/n8n/webhook/wamio-whatsapp-in`). No hay que tocar nada más acá.

### Paso 2 — Cargar el catálogo en Directus

1. Entrá a `https://tu-dominio/admin/` y logueate con `DIRECTUS_ADMIN_EMAIL` /
   `DIRECTUS_ADMIN_PASSWORD` del `.env`.
2. **Configuración inicial de tablas (una sola vez):** como las tablas de negocio
   se crean por SQL, la primera vez aparecen como *unmanaged* en
   **Settings → Data Model**. Activalas (categorías, productos, servicios,
   horarios_disponibilidad, turnos, clientes, pedidos, pedido_items) y configurá
   las relaciones (categoría ↔ producto, cliente ↔ turno, etc.).
3. Cargá el contenido real:
   - **Categorías** (ej. Alimentos, Higiene, Consultas).
   - **Productos** (nombre, precio, stock, categoría, activo sí/no).
   - **Servicios** (ej. Baño, Consulta veterinaria) con su precio y duración.
   - **Horarios de disponibilidad** (días y franjas en que se dan turnos).

### Paso 3 — Configurar Mercado Pago

1. Sacá tu **Access Token** de producción desde el panel de Mercado Pago
   (Tus integraciones → Credenciales).
2. Pegalo en el `.env` como `MP_ACCESS_TOKEN=...` y reiniciá n8n:
   `docker compose up -d n8n`.

### Paso 4 — Armar los flujos en n8n

Entrá a `https://tu-dominio/n8n/`. La primera vez te pide crear el usuario
**owner** (guardá esas credenciales). Después armás los 3 flujos —el detalle de
nodos está en el **[README, sección "Los 3 flujos"](README.md#los-3-flujos-a-armar-en-n8n)**:

- **a) Catálogo por WhatsApp** — el cliente pregunta y recibe productos/precios.
- **b) Reserva de turno** — calcula horarios libres, agenda y confirma.
- **c) Pago** — arma el pedido, genera el link de Mercado Pago y confirma el pago.

> **Webhooks públicos:** con n8n bajo `/n8n/`, la URL que le cargás a Mercado
> Pago para la notificación de pago es
> `https://tu-dominio/n8n/webhook/wamio-mp-webhook`.

---

## 5. El flujo de trabajo completo

### 5.1. Recorrido del cliente (automático)

```
1. Cliente escribe por WhatsApp: "¿Tenés turno para baño el jueves?"
        │
2. Evolution API recibe el mensaje y lo manda a n8n.
        │
3. n8n interpreta la intención:
     ├─ ¿pregunta por productos/precios? → consulta Postgres → responde catálogo
     ├─ ¿quiere turno?  → busca horarios libres → ofrece opciones → agenda
     └─ ¿quiere comprar/pagar? → arma pedido → genera link de Mercado Pago
        │
4. n8n responde por WhatsApp (vía Evolution API), con el catálogo, la
   confirmación del turno o el link de pago.
        │
5. Cliente paga por Mercado Pago.
        │
6. Mercado Pago notifica a n8n (webhook) → n8n marca el pedido como "pagado"
   y le confirma al cliente por WhatsApp.
```

Todo esto pasa **sin intervención humana**, 24/7. El comercio no toca el teléfono.

### 5.2. Recorrido del dueño del comercio (día a día)

| Cuándo            | Qué hacés                              | Dónde                       |
|-------------------|----------------------------------------|-----------------------------|
| Al empezar        | Conectar WhatsApp (una vez)            | Evolution Manager (`:8054`) |
| Setup / cambios   | Cargar/editar productos, precios, servicios, horarios | Directus `/admin/` |
| Todos los días    | Ver los turnos agendados y los pedidos | Directus `/admin/`          |
| Ocasional         | Ajustar respuestas/lógica de los flujos | n8n `/n8n/`                 |
| Cuando hace falta | Tomar una conversación a mano          | Chatwoot (opcional)         |

**Ejemplo de un día típico:**

1. A la mañana abrís **Directus** y mirás los **turnos** del día (colección
   `turnos`, filtrando por fecha). Todo lo agendó Wamio solo durante la noche.
2. Ves un **pedido** nuevo con `estado_pago = pagado`: preparás el producto para
   entregar/enviar.
3. Cargás dos **productos** nuevos que te llegaron de proveedor (quedan
   disponibles al instante para el catálogo por WhatsApp).
4. Un cliente tiene una consulta rara que el bot no resuelve: la tomás vos desde
   **Chatwoot** (si lo tenés activo) o directo desde el WhatsApp del comercio.

### 5.3. Los datos, por dentro

Todo queda registrado en la base `wamio` (accesible y editable desde Directus):

- `clientes` — quién escribió (teléfono, nombre).
- `categorias`, `productos`, `servicios` — tu catálogo.
- `horarios_disponibilidad` — cuándo das turnos.
- `turnos` — reservas (con `estado`: pendiente/confirmado/cancelado). Un índice
  único evita que se pise el mismo horario aunque dos clientes escriban a la vez.
- `pedidos` + `pedido_items` — compras, con `estado_pago` y datos de Mercado Pago.
  Cada ítem guarda `nombre_snapshot` y `precio_unit` del momento de la compra
  (si después cambiás el precio, el pedido viejo conserva el precio real cobrado).

---

## 6. Operación y mantenimiento

- **Reiniciar un servicio puntual:** `docker compose restart n8n` (o `directus`,
  `evolution-api`, `landing`).
- **Actualizar a la última imagen de CI:** `docker compose pull && docker compose up -d`.
- **Ver logs:** `docker compose logs -f n8n` (o el servicio que sea).
- **Activar Chatwoot (atención humana):** `docker compose --profile chatwoot up -d`
  y publicalo (si querés) en su propio subdominio apuntando a `wamio_chatwoot:3000`.
- **Backups:** ver el comando de `pg_dumpall` en el
  **[README, sección Seguridad y backups](README.md#seguridad-y-backups)**.
  Programalo como cron diario y guardá los `.sql` fuera del servidor.

---

## 7. Problemas frecuentes

| Síntoma                                             | Causa / solución                                                                 |
|-----------------------------------------------------|----------------------------------------------------------------------------------|
| La raíz del dominio no muestra la landing           | NPM no apunta a `wamio_landing:8080`, o el contenedor `landing` está caído (`docker compose ps`). |
| `/admin/` o `/n8n/` cargan a medias / assets rotos  | `WAMIO_PUBLIC_URL` en `.env` no coincide con el dominio real. Corregilo y `docker compose up -d`. |
| n8n redirige mal o los webhooks no llegan           | Revisá `N8N_HOST` (sin `https://`), `N8N_PROTOCOL=https` y que NPM tenga **Websockets Support** activo. |
| Evolution no conecta / no aparece el QR             | Entrá al Manager por el puerto `:8054`, no por `/api/` (esa ruta es solo la REST). |
| `database "..." does not exist` / `invalid port`    | Contraseñas con caracteres especiales o volumen ya inicializado. Ver **[Troubleshooting del README](README.md#troubleshooting)**. |

---

Con esto tenés el mapa completo: **qué es cada pieza, por qué ruta se entra a
cada una y cómo fluye el trabajo** desde el mensaje del cliente hasta el pago
registrado. Para el detalle técnico de instalación, imágenes y flujos de n8n,
seguí en el [README](README.md).
