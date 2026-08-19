# Alertas Grafana-managed

Aquí vive lo que **no puede ser una regla del ruler de Mimir**. Hoy es una sola alerta.

## Por qué existe este directorio

`observability/mimir-rules/` contiene reglas en formato Prometheus que `mimirtool` sincroniza
al ruler de nuestro tenant. Ese ruler tiene una limitación de diseño: **solo puede consultar
las series de su propio tenant**.

La guarda de coste necesita `grafanacloud_instance_active_series` y
`grafanacloud_instance_metrics_limits`, que Grafana publica en el datasource
`grafanacloud-usage` — **otro tenant**, de solo lectura y gestionado por Grafana. Comprobado:
esas métricas no existen en `grafanacloud-prom`.

Las alertas *Grafana-managed* sí pueden consultar cualquier datasource configurado en el
stack, así que son el mecanismo correcto para este caso. A cambio viven en otro sistema, con
otro formato y otro camino de despliegue.

| | Mimir ruler (`mimir-rules/`) | Grafana-managed (aquí) |
|---|---|---|
| Formato | reglas Prometheus (`namespace:` + `groups:`) | provisioning de Grafana (`apiVersion: 1`) |
| Despliegue | `mimirtool rules sync` desde CI | API de provisioning o importación en la UI |
| Puede consultar | solo el tenant propio | cualquier datasource del stack |
| Validación en PR | `mimirtool rules lint` + `check` | ninguna automática (ver abajo) |

**Importante:** `mimirtool rules sync` **no toca** estas alertas, y el workflow de calidad
tampoco las valida — su glob apunta a `mimir-rules/`. Son dos mundos separados a propósito;
no mezcles los ficheros de directorio o el sync fallará al parsear.

## Cómo aplicarla

Requisito previo: la carpeta `VetSoftware` debe existir en el stack (Alerting → Alert rules →
New folder), porque el fichero la referencia en `folder:`.

**Opción A — UI (la más rápida la primera vez).** Alerting → Alert rules → *Import alert
rules* → pegar el YAML. Grafana valida el formato al importar.

**Opción B — API de provisioning.** Con un token de Access Policy que tenga los scopes de
alerting (`alert.provisioning:read` y `alert.provisioning:write`):

```bash
curl -X POST "https://<stack>.grafana.net/api/v1/provisioning/alert-rules" \
  -H "Authorization: Bearer $GRAFANA_PROVISIONING_TOKEN" \
  -H "Content-Type: application/yaml" \
  --data-binary @vetsoftware-cost-guard.yml
```

No hay workflow de CI para esto todavía, y es deliberado: **una sola alerta no justifica un
segundo pipeline** con su propio token y su propia superficie de fallo. Si algún día hay
media docena de alertas Grafana-managed, el momento de automatizarlo será ese — y el patrón
a copiar es el de `sync-alert-rules-*.yml`.

## Qué vigila y por qué importa

`VetSoftwareIngestionNearLimit` avisa cuando las series activas superan el **80 %** del límite
del plan.

Los números medidos el 18 de agosto de 2026: **límite 15.000** series
(`max_active_series_per_user`), uso real entre **1.146 y 1.583** según el momento (7,6 %–10,5 %
— el backend de dev se apaga a las 20:00 y sus series expiran). Margen amplio, pero el riesgo
no es el crecimiento vegetativo:

- Las recording rules de SLO añaden ~300 series al activarse.
- La auditoría de observabilidad encontró que las métricas `email.*` llevan una etiqueta
  `error` **sin acotar** — el `MeterFilter` del backend solo cubre el prefijo
  `vetsoftware.business.`. Una excepción nueva del proveedor de correo crea series nuevas sin
  que nadie lo revise. `lettuce.*` está en la misma situación.

**Qué pasa si se llega al 100 %:** Grafana Cloud rechaza la ingesta. No se degrada, no avisa
en la aplicación: simplemente deja de aceptar métricas. Se pierde telemetría en silencio y con
ella la capacidad de ver cualquier otro incidente — incluidas las 22 alertas del ruler, que
dejarían de tener datos que evaluar. De ahí que sea la alerta que protege a todas las demás.

Otro límite del mismo bloque, que conviene tener presente aunque no tenga alerta:
**`ruler_max_rule_groups_per_tenant` = 85**, y los ficheros de `mimir-rules/` usan ~17 grupos.
Hay margen, pero no es infinito.
