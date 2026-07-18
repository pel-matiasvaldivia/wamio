FROM redis:7-alpine

# La imagen oficial ya crea el usuario redis; se fija explícitamente para
# no depender del entrypoint para el drop de privilegios.
USER redis
