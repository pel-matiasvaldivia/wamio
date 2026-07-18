# Postgres con los scripts de inicialización horneados en la imagen:
# la imagen es autocontenida y no depende de un bind mount del repo.
FROM postgres:16-alpine

COPY --chown=postgres:postgres --chmod=555 init-db/ /docker-entrypoint-initdb.d/

# El entrypoint oficial arranca como root para preparar el volumen y
# baja privilegios al usuario postgres; no se cambia USER acá.
