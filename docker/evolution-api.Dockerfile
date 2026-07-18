# Wrapper sobre Evolution API pineado: pasar por GHCR permite escanear la
# imagen en CI y controlar cuándo se adopta una versión nueva (upstream
# renombra variables de entorno entre releases).
FROM atendai/evolution-api:v2.2.3
