## Historia de usuario o tarea

Referencia:

## Qué cambia y por qué

## Cómo se verificó

## Promoción a qa o main

Commits reaplicados con `cherry-pick -x` (si aplica):

## Verificación

- [ ] Sin secretos ni credenciales (solo plantillas `.env.example`)
- [ ] Los archivos Compose son válidos (`docker compose config`)
- [ ] Sin esquemas ni migraciones de base de datos (viven en los repositorios `-db`)
- [ ] README y documentación coherentes con el cambio
