# Wamio

Plataforma self-hosted de venta y reservas por WhatsApp para comercios de barrio
(veterinarias, petshops, farmacias). Catálogo, turnos con calendario y cobro con
Mercado Pago, todo orquestado sin depender de la API oficial de Meta.

> 📖 **¿Cómo se usa la plataforma y cuál es el flujo de trabajo?**
> Ver **[GUIA.md](GUIA.md)** — manual completo de uso (rutas, primeros pasos y
> recorrido de punta a punta). Este README cubre la instalación y la parte técnica.

## Stack

| Servicio      | Rol                                                              |
|---------------|-------------------------------------------------------------------|
| `evolution-api` | Gateway de WhatsApp (Baileys, sin aprobación de Meta)            |
| `n8n`         | Orquestador: catálogo, turnos, pagos, recordatorios               |
| `postgres`    | Base de datos compartida (una DB por servicio)                    |
| `redis`       | Caché/colas para Evolution API, n8n y Directus                    |
| `directus`    | Panel admin auto-generado sobre la DB `wamio` (productos, turnos) |
| `landing`     | Landing pública + router del dominio (raíz, `/admin`, `/n8n`, `/api`) |
| `chatwoot`    | *(opcional)* bandeja de atención humana para handoff              |

## Imágenes Docker y CI

Las imágenes **no se bajan directo de Docker Hub**: se construyen en GitHub
Actions ([`build-images.yml`](.github/workflows/build-images.yml)) a partir de
los Dockerfiles de [`docker/`](docker/) y se publican en GHCR bajo
`ghcr.io/pel-matiasvaldivia/wamio/<servicio>`. El compose apunta a esas
imágenes, con `WAMIO_IMAGE_TAG` del `.env` (por defecto `latest`; también se
publica un tag por SHA de commit para deploys reproducibles).

El pipeline por cada servicio:
- **Lint** de los Dockerfiles con hadolint.
- **Build** con caché de capas (rápido: son wrappers finos sobre las imágenes
  oficiales pineadas, variantes alpine/slim, footprint mínimo).
- **Escaneo de vulnerabilidades** con Trivy (CRITICAL/HIGH con fix disponible);
  los resultados quedan en la pestaña **Security → Code scanning** del repo.
- **Push a GHCR** con SBOM y provenance (attestations de supply chain), solo en
  `main` — los PRs construyen y escanean pero no publican.
- **Rebuild semanal** programado para absorber parches de seguridad de las
  imágenes base sin cambiar de versión de aplicación.

Las versiones upstream se pinean en los Dockerfiles (`docker/*.Dockerfile`).
Para actualizar, cambiá la versión ahí y revisá el changelog del servicio
(Evolution API en particular renombra variables de entorno entre versiones).

Notas de uso:
- Si los paquetes de GHCR quedan **privados** (default), el servidor necesita
  `docker login ghcr.io` con un token con scope `read:packages`. Alternativa:
  hacer públicos los paquetes desde la página de cada package en GitHub.
- Sin acceso a GHCR (o para probar cambios locales), cada servicio tiene
  `build:` como fallback: `docker compose build && docker compose up -d`.
- Los scripts de `init-db/` van **horneados en la imagen de postgres** (ya no
  se montan por bind mount): si los cambiás, se necesita rebuild + recrear el
  volumen para que corran de nuevo (solo aplican en la primera inicialización).

## Arranque rápido

```bash
cp .env.example .env
# Editá .env y completá todas las claves marcadas "cambiar_esta_clave"

docker compose up -d
# Para incluir Chatwoot (atención humana):
docker compose --profile chatwoot up -d
```

En producción se entra por **un solo dominio** (contenedor `landing`), que
enruta cada servicio:

| Ruta pública            | Servicio      |
|-------------------------|---------------|
| `/`                     | Landing       |
| `/admin/`               | Directus      |
| `/n8n/`                 | n8n           |
| `/api/`                 | Evolution API (REST) |

Para depurar en el servidor, cada servicio también queda en su puerto directo:
- Landing/router: http://localhost:8060
- Evolution API (Manager para el QR): http://localhost:8054/manager
- n8n: http://localhost:5678
- Directus: http://localhost:8055
- Chatwoot (opcional): http://localhost:3056

> Detalle de rutas, accesos y flujo de trabajo: **[GUIA.md](GUIA.md)**.

## Primeros pasos

1. **Conectar WhatsApp**: entrá a Evolution API, creá una instancia y escaneá el
   QR con el WhatsApp del comercio.
2. **Crear el usuario de n8n**: el primer acceso a http://localhost:5678 pide
   crear la cuenta *owner* (n8n ya no usa basic auth; el gestor de usuarios
   propio protege la instancia).
3. **Cargar el catálogo**: entrá a Directus (`ADMIN_EMAIL` / `ADMIN_PASSWORD` del
   `.env`) y cargá categorías, productos y servicios desde el panel — no requiere
   tocar código.

   > Nota: como las tablas de `wamio` se crean por SQL y no desde Directus,
   > aparecen una única vez como *unmanaged* en **Settings → Data Model**.
   > Activalas y configurá las relaciones (categoría ↔ producto, cliente ↔
   > turno, etc.) desde ahí; es una configuración de una sola vez.
4. **Armar los flujos en n8n** (ver abajo).
5. **Configurar Mercado Pago**: cargá tu `MP_ACCESS_TOKEN` en el `.env` antes de
   levantar n8n.

## Los 3 flujos a armar en n8n

### a) Catálogo por WhatsApp
- Trigger: Webhook `wamio-whatsapp-in` (ya configurado como destino global en
  Evolution API).
- Nodo Postgres: `SELECT` sobre `productos`/`servicios` (activos) en la base
  `wamio`, filtrando por la palabra clave o categoría que escribió el cliente.
- Nodo HTTP Request: llamar a Evolution API (`/message/sendText` o
  `/message/sendList`) para responder con el listado y precios.

### b) Reserva de turno
- Trigger: el cliente elige un servicio (mensaje interactivo o texto tipo "quiero
  turno para baño el jueves").
- Nodo Postgres: consultar `horarios_disponibilidad` + `turnos` existentes para
  calcular huecos libres ese día (excluir horarios ya ocupados).
- Nodo IF: si hay disponibilidad, `INSERT` en `turnos` con estado `pendiente` y
  responder confirmando horario; si no, ofrecer las próximas opciones libres.
- El esquema tiene un índice único parcial (`idx_turnos_slot_unico`) que impide
  la doble reserva del mismo horario aunque dos clientes escriban a la vez: si
  el `INSERT` falla por conflicto, respondé ofreciendo otro horario.

### c) Pago
- Trigger: continuación del flujo de compra/turno, cuando el pedido está armado.
- Nodo Postgres: `INSERT` en `pedidos` (y `pedido_items` si son productos,
  copiando `nombre_snapshot` y `precio_unit` del producto al momento de la
  compra) con `estado_pago = 'pendiente'`.
- Nodo HTTP Request: crear preferencia de pago en Mercado Pago
  (`POST https://api.mercadopago.com/checkout/preferences`, header
  `Authorization: Bearer {{ $env.MP_ACCESS_TOKEN }}`), guardar el
  `mp_preference_id` devuelto en `pedidos`.
- Nodo HTTP Request: enviar el link de pago al cliente por WhatsApp.
- Segundo Webhook (`wamio-mp-webhook`): recibe la notificación de Mercado Pago
  cuando se acredita el pago, actualiza `pedidos.estado_pago = 'pagado'` y
  `mp_payment_id`, y le confirma el pago al cliente por WhatsApp.

> El compose ya setea `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` para que
> `{{ $env.MP_ACCESS_TOKEN }}` y `{{ $env.EVOLUTION_API_KEY }}` funcionen en
> las expresiones. Alternativa más prolija: guardarlas como *Credentials* de
> n8n en vez de variables de entorno.

## Seguridad y backups

- Todas las claves del `.env` deben generarse únicas y largas (`openssl rand -hex 32`).
  No reutilices contraseñas entre servicios.
- No expongas `postgres` ni `redis` a internet: no tienen `ports` mapeados en el
  compose, solo son accesibles dentro de la red interna `wamio_net`.
- Los puertos que sí quedan expuestos (`8080`, `5678`, `8055`, `3000`) deberían ir
  detrás de un reverse proxy con HTTPS (Traefik, Nginx + Certbot) antes de salir a
  producción — este compose no lo incluye para mantenerlo simple en desarrollo.
- Backup de Postgres (todas las bases, incluida `wamio` con productos/turnos/pedidos),
  usando el usuario definido en `POSTGRES_USER`:

  ```bash
  docker exec wamio_postgres pg_dumpall -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2)" > backup_$(date +%F).sql
  ```

- Programá ese comando como cron diario y guardá los `.sql` fuera del servidor
  (S3, otro disco, etc.).

## Troubleshooting

### `invalid port number in database URL` / `ECONNREFUSED 127.0.0.1:6379` / `database "x" does not exist`

Casi siempre es **un caracter especial en la contraseña**. `POSTGRES_PASSWORD`
y `REDIS_PASSWORD` se inyectan dentro de cadenas de conexión con formato URL
(`postgresql://user:PASS@host` y `redis://:PASS@host`). Si la contraseña
contiene `# @ : / ? & % +` o espacios, el parser de la URL se rompe:

- **Evolution API** → `P1013: The provided database string is invalid. invalid
  port number in database URL` (el `#` corta la URL antes del `:5432`).
- **Directus** → `The URL redis://:...@redis:6379/2 is invalid` y como fallback
  intenta `127.0.0.1:6379` → `ECONNREFUSED`.

**Solución:** usá contraseñas solo alfanuméricas (`openssl rand -hex 32`).
Como la contraseña de Postgres se fija cuando el volumen se inicializa por
primera vez, cambiarla en el `.env` no basta: hay que reinicializar el volumen.

### `database "n8n" / "wamio" / "evolution" does not exist`

Los scripts de `init-db/` **solo corren la primera vez que el volumen de
Postgres está vacío**. Si el stack levantó alguna vez con el volumen ya
inicializado (o antes de que los scripts estuvieran horneados en la imagen),
las bases nunca se crearon y todos los servicios fallan al conectar.

**Reset limpio (borra los volúmenes; hacelo solo si todavía no hay datos que
te importen — WhatsApp sin vincular, Directus sin cargar, etc.):**

```bash
# 1) Arreglá las contraseñas en .env (alfanuméricas, sin caracteres de URL)
openssl rand -hex 32   # generá una para POSTGRES_PASSWORD
openssl rand -hex 32   # y otra para REDIS_PASSWORD

# 2) Bajá el stack y BORRÁ los volúmenes (re-crea las bases desde init-db/)
docker compose down -v

# 3) Traé las imágenes y levantá de nuevo
docker compose pull
docker compose up -d

# 4) Verificá que las bases se crearon
docker exec wamio_postgres psql -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2)" -lqt | cut -d'|' -f1
#   Deberías ver: evolution, n8n, wamio, chatwoot
```

Si el stack **ya tiene datos** que no querés perder, en lugar de `down -v`:
creá las bases a mano y actualizá la contraseña del rol —
`docker exec -it wamio_postgres psql -U <user> -c "CREATE DATABASE n8n;"`
(idem `wamio`, `evolution`, `chatwoot`) y
`ALTER USER <user> WITH PASSWORD '<nueva-alfanumérica>';` — y dejá esa misma
contraseña en el `.env`.

### Detrás de Nginx Proxy Manager (dominio público)

El stack expone **un único punto de entrada** (contenedor `landing`), que
enruta internamente `/`, `/admin`, `/n8n` y `/api`. En el `.env`:

```
WAMIO_PUBLIC_URL=https://tu-dominio.com
N8N_HOST=tu-dominio.com          # sin https://
N8N_PROTOCOL=https
```

En NPM alcanza con **un solo Proxy Host**:

- **Domain Names:** `tu-dominio.com`
- **Forward Hostname / IP:** `wamio_landing` · **Forward Port:** `8080`
- **Websockets Support:** ✅ activado (n8n y Directus lo necesitan)
- **SSL:** Let's Encrypt + "Force SSL"

El router del contenedor `landing` reenvía cada ruta al servicio interno con los
headers correctos, así que no hace falta un Proxy Host por servicio. El detalle
de rutas y accesos está en **[GUIA.md](GUIA.md)**.
