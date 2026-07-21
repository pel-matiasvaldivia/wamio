#!/bin/bash
# Aplica el esquema de negocio dentro de la base "wamio" (creada en 01-create-databases.sh).
#
# Modelo MULTI-TENANT (SaaS): un solo despliegue atiende a muchos comercios.
# Cada comercio es una fila en "comercios" y TODO dato de negocio lleva
# comercio_id. El aislamiento (cada comercio ve solo lo suyo) lo aplica Directus
# con políticas por fila sobre comercio_id. Ver ARQUITECTURA.md.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "wamio" <<-'EOSQL'

-- ============================================================
-- COMERCIOS (tenants): cada cliente del SaaS
-- ============================================================
CREATE TABLE comercios (
    id                 SERIAL PRIMARY KEY,
    nombre             VARCHAR(150) NOT NULL,
    slug               VARCHAR(80) UNIQUE NOT NULL,   -- identificador corto (URLs / instancia)
    rubro              VARCHAR(80),                    -- veterinaria, petshop, farmacia...
    -- WhatsApp: nombre de la instancia en Evolution API (una por comercio)
    evolution_instance VARCHAR(120) UNIQUE,
    -- Mercado Pago: cada comercio cobra en su propia cuenta
    mp_access_token    TEXT,
    zona_horaria       VARCHAR(60) NOT NULL DEFAULT 'America/Argentina/Mendoza',
    plan               VARCHAR(30) NOT NULL DEFAULT 'free',
    activo             BOOLEAN NOT NULL DEFAULT true,
    creado_en          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- CLIENTES (los clientes finales de cada comercio)
-- ============================================================
CREATE TABLE clientes (
    id            SERIAL PRIMARY KEY,
    comercio_id   INTEGER NOT NULL REFERENCES comercios(id) ON DELETE CASCADE,
    nombre        VARCHAR(150),
    telefono      VARCHAR(30) NOT NULL,          -- número de WhatsApp (con código de país)
    email         VARCHAR(150),
    notas         TEXT,
    creado_en     TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- el mismo teléfono puede ser cliente de varios comercios, pero único dentro de uno
    UNIQUE (comercio_id, telefono)
);
CREATE INDEX idx_clientes_comercio ON clientes(comercio_id);

-- ============================================================
-- CATEGORÍAS (opcional, para ordenar el catálogo por rubro)
-- ============================================================
CREATE TABLE categorias (
    id            SERIAL PRIMARY KEY,
    comercio_id   INTEGER NOT NULL REFERENCES comercios(id) ON DELETE CASCADE,
    nombre        VARCHAR(100) NOT NULL,
    orden         INTEGER DEFAULT 0
);
CREATE INDEX idx_categorias_comercio ON categorias(comercio_id);

-- ============================================================
-- PRODUCTOS (venta directa: alimento, medicamentos, accesorios)
-- ============================================================
CREATE TABLE productos (
    id            SERIAL PRIMARY KEY,
    comercio_id   INTEGER NOT NULL REFERENCES comercios(id) ON DELETE CASCADE,
    categoria_id  INTEGER REFERENCES categorias(id) ON DELETE SET NULL,
    nombre        VARCHAR(150) NOT NULL,
    descripcion   TEXT,
    precio        NUMERIC(12,2) NOT NULL CHECK (precio >= 0),
    stock         INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
    imagen_url    TEXT,
    activo        BOOLEAN NOT NULL DEFAULT true,
    creado_en     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_productos_comercio ON productos(comercio_id);
CREATE INDEX idx_productos_categoria ON productos(categoria_id);

-- ============================================================
-- SERVICIOS (turnos: baño, peluquería, consulta veterinaria)
-- ============================================================
CREATE TABLE servicios (
    id                SERIAL PRIMARY KEY,
    comercio_id       INTEGER NOT NULL REFERENCES comercios(id) ON DELETE CASCADE,
    categoria_id      INTEGER REFERENCES categorias(id) ON DELETE SET NULL,
    nombre            VARCHAR(150) NOT NULL,
    descripcion       TEXT,
    precio            NUMERIC(12,2) NOT NULL CHECK (precio >= 0),
    duracion_minutos  INTEGER NOT NULL DEFAULT 30 CHECK (duracion_minutos > 0),
    activo            BOOLEAN NOT NULL DEFAULT true,
    creado_en         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_servicios_comercio ON servicios(comercio_id);
CREATE INDEX idx_servicios_categoria ON servicios(categoria_id);

-- ============================================================
-- HORARIOS DE DISPONIBILIDAD (por día de semana, para calcular turnos libres)
-- ============================================================
CREATE TABLE horarios_disponibilidad (
    id            SERIAL PRIMARY KEY,
    comercio_id   INTEGER NOT NULL REFERENCES comercios(id) ON DELETE CASCADE,
    dia_semana    SMALLINT NOT NULL CHECK (dia_semana BETWEEN 0 AND 6), -- 0=domingo
    hora_inicio   TIME NOT NULL,
    hora_fin      TIME NOT NULL,
    activo        BOOLEAN NOT NULL DEFAULT true,
    CHECK (hora_fin > hora_inicio)
);
CREATE INDEX idx_horarios_comercio ON horarios_disponibilidad(comercio_id);

-- ============================================================
-- TURNOS / RESERVAS
-- ============================================================
CREATE TABLE turnos (
    id             SERIAL PRIMARY KEY,
    comercio_id    INTEGER NOT NULL REFERENCES comercios(id) ON DELETE CASCADE,
    cliente_id     INTEGER NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    servicio_id    INTEGER NOT NULL REFERENCES servicios(id) ON DELETE RESTRICT,
    fecha_hora     TIMESTAMPTZ NOT NULL,
    estado         VARCHAR(20) NOT NULL DEFAULT 'pendiente'
                   CHECK (estado IN ('pendiente','confirmado','cancelado','completado')),
    notas          TEXT,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_turnos_comercio ON turnos(comercio_id);
CREATE INDEX idx_turnos_fecha ON turnos(fecha_hora);
CREATE INDEX idx_turnos_estado ON turnos(estado);
CREATE INDEX idx_turnos_cliente ON turnos(cliente_id);
CREATE INDEX idx_turnos_servicio ON turnos(servicio_id);

-- Evita la doble reserva del mismo horario para un servicio, incluso con
-- inserts concurrentes desde n8n (los cancelados/completados no bloquean).
-- Incluye comercio_id por claridad (servicio_id ya es único por comercio).
CREATE UNIQUE INDEX idx_turnos_slot_unico
    ON turnos(comercio_id, servicio_id, fecha_hora)
    WHERE estado IN ('pendiente','confirmado');

-- ============================================================
-- PEDIDOS (compra de productos y/o contratación de servicios)
-- ============================================================
CREATE TABLE pedidos (
    id                  SERIAL PRIMARY KEY,
    comercio_id         INTEGER NOT NULL REFERENCES comercios(id) ON DELETE CASCADE,
    cliente_id          INTEGER NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    turno_id            INTEGER REFERENCES turnos(id) ON DELETE SET NULL,
    total               NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
    estado_pago         VARCHAR(20) NOT NULL DEFAULT 'pendiente'
                        CHECK (estado_pago IN ('pendiente','pagado','rechazado','reembolsado')),
    mp_payment_id       VARCHAR(100),   -- id de pago de Mercado Pago
    mp_preference_id    VARCHAR(100),   -- id de preferencia / link de pago
    creado_en           TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_pedidos_comercio ON pedidos(comercio_id);
CREATE INDEX idx_pedidos_cliente ON pedidos(cliente_id);
CREATE INDEX idx_pedidos_estado_pago ON pedidos(estado_pago);
-- El webhook de Mercado Pago busca el pedido por estos campos
CREATE INDEX idx_pedidos_mp_preference ON pedidos(mp_preference_id);
CREATE INDEX idx_pedidos_mp_payment ON pedidos(mp_payment_id);

-- pedido_items hereda el comercio vía su pedido (Directus filtra por la relación
-- pedido.comercio_id), así que no se desnormaliza acá.
CREATE TABLE pedido_items (
    id              SERIAL PRIMARY KEY,
    pedido_id       INTEGER NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
    producto_id     INTEGER REFERENCES productos(id) ON DELETE SET NULL,
    -- snapshot al momento de la compra: el historial del pedido sobrevive
    -- aunque el producto se borre o cambie de precio
    nombre_snapshot VARCHAR(150) NOT NULL,
    cantidad        INTEGER NOT NULL DEFAULT 1 CHECK (cantidad > 0),
    precio_unit     NUMERIC(12,2) NOT NULL CHECK (precio_unit >= 0)
);
CREATE INDEX idx_pedido_items_pedido ON pedido_items(pedido_id);

-- ============================================================
-- AUDITORÍA: mantiene actualizado_en al día en turnos y pedidos
-- ============================================================
CREATE FUNCTION set_actualizado_en() RETURNS trigger AS $$
BEGIN
    NEW.actualizado_en := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_turnos_actualizado
    BEFORE UPDATE ON turnos
    FOR EACH ROW EXECUTE FUNCTION set_actualizado_en();

CREATE TRIGGER trg_pedidos_actualizado
    BEFORE UPDATE ON pedidos
    FOR EACH ROW EXECUTE FUNCTION set_actualizado_en();

-- ============================================================
-- COMERCIO DEMO: para probar el panel de entrada sin registro todavía.
-- (Fase 4 reemplaza esto por el alta real de comercios.)
-- ============================================================
INSERT INTO comercios (nombre, slug, rubro)
VALUES ('Comercio Demo', 'demo', 'veterinaria');

EOSQL

echo "Esquema multi-tenant aplicado en la base 'wamio' (tabla comercios + comercio_id)"
