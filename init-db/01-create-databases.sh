#!/bin/bash
# Crea una base de datos separada por servicio dentro del mismo contenedor Postgres.
# Evolution API, n8n y Directus quedan aislados entre sí; "wamio" es la base de
# negocio (productos, turnos, clientes, pedidos) que Directus expone como panel admin.
#
# Idempotente: si una base ya existe, la saltea (útil si el script se corre a mano).
set -e

# --dbname explícito: sin él, psql se conecta por defecto a una base con el
# nombre del usuario (que no existe) y falla. Necesario para poder correr el
# script a mano con `docker exec`, no solo durante el init automático.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${POSTGRES_DB:-postgres}" <<-'EOSQL'
    SELECT 'CREATE DATABASE evolution' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'evolution')\gexec
    SELECT 'CREATE DATABASE n8n'       WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n')\gexec
    SELECT 'CREATE DATABASE wamio'     WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'wamio')\gexec
    SELECT 'CREATE DATABASE chatwoot'  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot')\gexec
EOSQL

echo "Bases de datos creadas: evolution, n8n, wamio, chatwoot"
echo "Directus se conecta directamente a 'wamio' para administrar las tablas de negocio"
