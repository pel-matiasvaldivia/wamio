#!/bin/bash
# Aplica el esquema de negocio dentro de la base "wamio" (creada en 01-create-databases.sh).
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "wamio" <<-'EOSQL'

-- ============================================================
-- CLIENTES
-- ============================================================
CREATE TABLE clientes (
    id            SERIAL PRIMARY KEY,
    nombre        VARCHAR(150),
    telefono      VARCHAR(30) UNIQUE NOT NULL,  -- número de WhatsApp (con código de país)
    email         VARCHAR(150),
    notas         TEXT,
    creado_en     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- CATEGORÍAS (opcional, para ordenar el catálogo por rubro)
-- ============================================================
CREATE TABLE categorias (
    id            SERIAL PRIMARY KEY,
    nombre        VARCHAR(100) NOT NULL,
    orden         INTEGER DEFAULT 0
);

-- ============================================================
-- PRODUCTOS (venta directa: alimento, medicamentos, accesorios)
-- ============================================================
CREATE TABLE productos (
    id            SERIAL PRIMARY KEY,
    categoria_id  INTEGER REFERENCES categorias(id) ON DELETE SET NULL,
    nombre        VARCHAR(150) NOT NULL,
    descripcion   TEXT,
    precio        NUMERIC(12,2) NOT NULL CHECK (precio >= 0),
    stock         INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
    imagen_url    TEXT,
    activo        BOOLEAN NOT NULL DEFAULT true,
    creado_en     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_productos_categoria ON productos(categoria_id);

-- ============================================================
-- SERVICIOS (turnos: baño, peluquería, consulta veterinaria)
-- ============================================================
CREATE TABLE servicios (
    id                SERIAL PRIMARY KEY,
    categoria_id      INTEGER REFERENCES categorias(id) ON DELETE SET NULL,
    nombre            VARCHAR(150) NOT NULL,
    descripcion       TEXT,
    precio            NUMERIC(12,2) NOT NULL CHECK (precio >= 0),
    duracion_minutos  INTEGER NOT NULL DEFAULT 30 CHECK (duracion_minutos > 0),
    activo            BOOLEAN NOT NULL DEFAULT true,
    creado_en         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_servicios_categoria ON servicios(categoria_id);

-- ============================================================
-- HORARIOS DE DISPONIBILIDAD (por día de semana, para calcular turnos libres)
-- ============================================================
CREATE TABLE horarios_disponibilidad (
    id            SERIAL PRIMARY KEY,
    dia_semana    SMALLINT NOT NULL CHECK (dia_semana BETWEEN 0 AND 6), -- 0=domingo
    hora_inicio   TIME NOT NULL,
    hora_fin      TIME NOT NULL,
    activo        BOOLEAN NOT NULL DEFAULT true,
    CHECK (hora_fin > hora_inicio)
);

-- ============================================================
-- TURNOS / RESERVAS
-- ============================================================
CREATE TABLE turnos (
    id             SERIAL PRIMARY KEY,
    cliente_id     INTEGER NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
    servicio_id    INTEGER NOT NULL REFERENCES servicios(id) ON DELETE RESTRICT,
    fecha_hora     TIMESTAMPTZ NOT NULL,
    estado         VARCHAR(20) NOT NULL DEFAULT 'pendiente'
                   CHECK (estado IN ('pendiente','confirmado','cancelado','completado')),
    notas          TEXT,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_turnos_fecha ON turnos(fecha_hora);
CREATE INDEX idx_turnos_estado ON turnos(estado);
CREATE INDEX idx_turnos_cliente ON turnos(cliente_id);
CREATE INDEX idx_turnos_servicio ON turnos(servicio_id);

-- Evita la doble reserva del mismo horario para un servicio, incluso con
-- inserts concurrentes desde n8n (los cancelados/completados no bloquean).
CREATE UNIQUE INDEX idx_turnos_slot_unico
    ON turnos(servicio_id, fecha_hora)
    WHERE estado IN ('pendiente','confirmado');

-- ============================================================
-- PEDIDOS (compra de productos y/o contratación de servicios)
-- ============================================================
CREATE TABLE pedidos (
    id                  SERIAL PRIMARY KEY,
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
CREATE INDEX idx_pedidos_cliente ON pedidos(cliente_id);
CREATE INDEX idx_pedidos_estado_pago ON pedidos(estado_pago);
-- El webhook de Mercado Pago busca el pedido por estos campos
CREATE INDEX idx_pedidos_mp_preference ON pedidos(mp_preference_id);
CREATE INDEX idx_pedidos_mp_payment ON pedidos(mp_payment_id);

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

EOSQL

echo "Esquema de negocio aplicado en la base 'wamio'"
