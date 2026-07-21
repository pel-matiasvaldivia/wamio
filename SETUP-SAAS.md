# Puesta a punto del SaaS (operador) — una sola vez

Esto lo hacés **vos** (el operador) una única vez en Directus para que el panel
del comercio (`/app`) funcione con aislamiento por comercio. El comercio nunca
ve nada de esto: solo entra a `https://wamio.pymesenlinea.com.ar/app` y usa su
panel.

> Referencia del modelo en [ARQUITECTURA.md](ARQUITECTURA.md). El panel web está
> en `app/` y se sirve en `/app/`.

## 0. Aplicar el esquema multi-tenant

Si venías de la versión anterior, reiniciá el volumen para tomar el nuevo
esquema (`comercios` + `comercio_id`). Todavía sin datos productivos:

```bash
git pull && docker compose pull
docker compose down -v && docker compose up -d
```

## 1. Registrar las colecciones en Directus

Entrá a `/admin` → **Settings → Data Model**. Cada tabla aparece como
*Database Only*. Hacé click en cada una → **Click to Configure** → guardá:
`comercios`, `clientes`, `categorias`, `productos`, `servicios`,
`horarios_disponibilidad`, `turnos`, `pedidos`, `pedido_items`.

## 2. Vincular usuarios a un comercio

**Settings → Data Model → Users (`directus_users`) → Create Field:**
- Tipo: **Many-to-One**
- Clave del campo: `comercio`
- Colección relacionada: `comercios`

Esto permite decir "este usuario pertenece a este comercio".

## 3. Crear la Access Policy "Comercio"

**Settings → Access Policies → Create Policy** → nombre `Comercio`,
**App Access: ON**. Agregá permisos con este filtro en cada colección:

| Colección | Permisos | Filtro (Item Permissions) |
|-----------|----------|----------------------------|
| `comercios` | Read | `id` **=** `$CURRENT_USER.comercio` |
| `productos` | Create, Read, Update, Delete | `comercio_id` **=** `$CURRENT_USER.comercio` |
| `servicios` | Create, Read, Update, Delete | `comercio_id` **=** `$CURRENT_USER.comercio` |
| `categorias` | Create, Read, Update, Delete | `comercio_id` **=** `$CURRENT_USER.comercio` |
| `clientes` | Read, Update | `comercio_id` **=** `$CURRENT_USER.comercio` |
| `horarios_disponibilidad` | Create, Read, Update, Delete | `comercio_id` **=** `$CURRENT_USER.comercio` |
| `turnos` | Read, Update | `comercio_id` **=** `$CURRENT_USER.comercio` |
| `pedidos` | Read | `comercio_id` **=** `$CURRENT_USER.comercio` |
| `pedido_items` | Read | `pedido_id.comercio_id` **=** `$CURRENT_USER.comercio` |

> En **Create/Update** de `productos`, `servicios`, `categorias` y
> `horarios_disponibilidad`, poné también en **Validation** la misma condición
> `comercio_id = $CURRENT_USER.comercio`. Así un comercio no puede crear datos a
> nombre de otro. El panel ya manda el `comercio_id` correcto automáticamente.

## 4. Crear el rol y el usuario del comercio

1. **Settings → Roles → Create Role** → nombre `Comercio` → asignale la policy
   `Comercio` del paso 3.
2. **User Directory → Create User**:
   - Email + contraseña (estas son las credenciales que le pasás al comercio).
   - **Role:** `Comercio`.
   - **Comercio:** `Comercio Demo` (o el comercio real).

## 5. Probar

Entrá a `https://wamio.pymesenlinea.com.ar/app`, logueate con ese usuario y vas
a ver el panel con **solo los datos de ese comercio**. Cargá un producto de
prueba y confirmá que aparece.

---

### Dar de alta un comercio nuevo (hasta que exista el registro automático, Fase 4)

1. **Content → Comercios → Create**: nombre, slug, rubro.
2. **User Directory → Create User**: rol `Comercio`, campo `comercio` = el
   comercio recién creado, email + contraseña.
3. Le pasás al comercio la URL `/app` y sus credenciales. Listo.

Este flujo manual se reemplaza en la **Fase 2** (conectar WhatsApp desde la web)
y **Fase 4** (registro y planes).
