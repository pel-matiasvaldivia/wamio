# Landing + router público de Wamio.
# Imagen no-root (escucha en 8080) para mantener el footprint mínimo y seguro:
# no necesita privilegios de root para bindear un puerto < 1024.
FROM nginxinc/nginx-unprivileged:1.27-alpine

# Config del reverse proxy interno (raíz -> landing, /admin, /n8n, /api).
COPY landing/nginx.conf /etc/nginx/conf.d/default.conf

# Página de marketing (lo primero que ve el visitante en la raíz del dominio).
COPY landing/index.html /usr/share/nginx/html/index.html

# Panel del comercio (SPA servida en /app/).
COPY app/ /usr/share/nginx/html/app/

EXPOSE 8080

# Chequeo de salud del contenedor (wget de busybox, resuelto por PATH).
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://127.0.0.1:8080/healthz || exit 1
