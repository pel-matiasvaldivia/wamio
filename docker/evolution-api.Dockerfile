# Wrapper sobre Evolution API pineado: pasar por GHCR permite escanear la
# imagen en CI y controlar cuándo se adopta una versión nueva (upstream
# renombra variables de entorno entre releases).
# Ojo: el proyecto movió sus imágenes de atendai/ a evoapicloud/ en Docker Hub.
FROM evoapicloud/evolution-api:v2.3.7
