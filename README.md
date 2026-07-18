# Wamio

Plataforma self-hosted de venta y reservas por WhatsApp para comercios de barrio
(veterinarias, petshops, farmacias). Catálogo, turnos con calendario y cobro con
Mercado Pago, todo orquestado sin depender de la API oficial de Meta.

## Stack

| Servicio      | Rol                                                              |
|---------------|-------------------------------------------------------------------|
| `evolution-api` | Gateway de WhatsApp (Baileys, sin aprobación de Meta)            |
| `n8n`         | Orquestador: catálogo, turnos, pagos, recordatorios               |
| `postgres`    | Base de datos compartida (una DB por servicio)                    |
| `redis`       | Caché/colas para Evolution API, n8n y Directus                    |
| `directus`    | Panel admin auto-generado sobre la DB `wamio` (productos, turnos) |
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

Servicios disponibles:
- Evolution API: http://localhost:8080
- n8n: http://localhost:5678
- Directus: http://localhost:8055
- Chatwoot (opcional): http://localhost:3000

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
