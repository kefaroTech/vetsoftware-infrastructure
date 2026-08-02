# Política obligatoria de GitFlow

Esta política es obligatoria para cualquier persona, agente de IA, automatización o herramienta que realice operaciones Git en este repositorio. No se permiten atajos, incluso para cambios pequeños, documentación, configuración o mantenimiento.

## Ramas permanentes

- `main` representa únicamente código liberado o listo para producción.
- `develop` es la rama de integración del siguiente ciclo de desarrollo.
- Está prohibido crear commits directamente en `main` o `develop`.
- Está prohibido desarrollar con el árbol de trabajo posicionado en `main` o `develop`.

## Ramas temporales permitidas

- `feature/<descripcion>`: nace exclusivamente desde `develop` y se integra exclusivamente en `develop`. Todo trabajo normal usa este tipo, incluyendo funcionalidades, correcciones no urgentes, refactorizaciones, documentación, pruebas, CI/CD y mantenimiento.
- `release/<version>`: nace exclusivamente desde `develop`. Solo puede contener preparación de versión, correcciones de estabilización y metadatos de release. Se integra en `main` y después en `develop`.
- `hotfix/<version-o-descripcion>`: nace exclusivamente desde `main` para una corrección urgente de producción. Se integra en `main` y después en `develop`.

No se permiten ramas de trabajo creadas desde otra rama temporal ni ramas con flujo distinto a los anteriores.

## Procedimiento obligatorio

1. Antes de cualquier operación, inspeccionar el estado, la rama actual, las ramas existentes y los remotos. Nunca descartar, sobrescribir ni mezclar cambios locales ajenos.
2. Actualizar la rama base correspondiente mediante un avance seguro antes de crear la rama temporal. No continuar si existen cambios sin confirmar o divergencias inesperadas.
3. Crear la rama temporal correcta antes de modificar archivos o generar commits.
4. Hacer commits atómicos, verificables y con el formato de mensajes exigido por el repositorio. No omitir hooks con `--no-verify`.
5. Ejecutar las validaciones proporcionales al cambio antes de integrar. No integrar con conflictos, pruebas fallidas o un árbol de trabajo sucio.
6. Integrar siempre con un merge explícito `--no-ff`. Están prohibidos los merges fast-forward para cerrar ramas, el squash merge y el rebase de ramas compartidas.
7. Eliminar la rama temporal local y remota solo después de confirmar que quedó integrada en todos sus destinos obligatorios.

## Flujo de integración

### Feature

1. Crear `feature/*` desde `develop`.
2. Realizar y validar los commits en `feature/*`.
3. Integrar `feature/*` en `develop` con `--no-ff`.
4. Eliminar `feature/*` después de verificar el merge.

### Release

1. Crear `release/<version>` desde `develop`.
2. Estabilizar y validar la versión sin añadir funcionalidades nuevas.
3. Integrar `release/<version>` en `main` con `--no-ff`.
4. Crear en `main` una etiqueta anotada de versión, siguiendo SemVer cuando aplique.
5. Integrar `release/<version>` en `develop` con `--no-ff` para devolver cualquier ajuste de release.
6. Eliminar `release/<version>` después de verificar ambos merges y la etiqueta.

### Hotfix

1. Crear `hotfix/*` desde `main`.
2. Aplicar y validar únicamente la corrección urgente.
3. Integrar `hotfix/*` en `main` con `--no-ff` y crear la etiqueta de versión correspondiente.
4. Integrar `hotfix/*` en `develop` con `--no-ff`.
5. Eliminar `hotfix/*` después de verificar ambos merges.

## Prohibiciones

- No hacer commits directos, cherry-picks rutinarios ni pushes directos a `main` o `develop`.
- No actualizar `main` directamente desde `develop`; toda promoción normal debe pasar por `release/*`.
- No usar `push --force`, reescribir historial publicado ni eliminar ramas no integradas.
- No mezclar una feature directamente en `main`.
- No saltarse ramas, validaciones, commits, merges o etiquetas obligatorias aunque el repositorio todavía no tenga remoto configurado.
- Si una petición contradice esta política, detener la operación y explicar el flujo GitFlow correcto antes de continuar.
