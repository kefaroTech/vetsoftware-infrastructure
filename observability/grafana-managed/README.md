# Alerting Grafana-managed

Aquí vive lo que **no puede ser una regla del ruler de Mimir**: la configuración del sistema
de alerting de Grafana propiamente dicho. Hoy son tres ficheros:

| Fichero | Qué es | ¿Funciona hoy? |
|---|---|---|
| `vetsoftware-cost-guard.yml` | 1 alerta Grafana-managed (`VetSoftwareIngestionNearLimit`) | Sí |
| `vetsoftware-contact-points.yml` | 2 contact points (`vetsoftware-critical`, `vetsoftware-warning`) | Email sí (nativo de Grafana Cloud); Slack escrito pero **comentado hasta que exista el webhook** |
| `vetsoftware-notification-policy.yml` | El árbol de enrutado: raíz + una route por `severity` | Sí, en cuanto existan los contact points |

## Por qué existe este directorio

`observability/mimir-rules/` contiene reglas en formato Prometheus que `mimirtool` sincroniza
al ruler de nuestro tenant. Hay dos cosas que ese camino no puede expresar:

1. **Alertas que consultan otro tenant.** El ruler solo puede consultar las series de su
   propio tenant, y la guarda de coste necesita `grafanacloud_instance_active_series` y
   `grafanacloud_instance_metrics_limits`, que viven en el datasource `grafanacloud-usage`
   — otro tenant, de solo lectura y gestionado por Grafana. Comprobado: esas métricas no
   existen en `grafanacloud-prom`. Las alertas *Grafana-managed* sí pueden consultar
   cualquier datasource del stack.
2. **La entrega.** Contact points y notification policy no son conceptos del ruler: el ruler
   evalúa y dispara, pero quién recibe qué, agrupado cómo y repetido cada cuánto es
   configuración de Alertmanager. Sin estos ficheros, las 24 alertas del ruler **evalúan
   pero no notifican a nadie** — que es exactamente el estado en que estaba el stack antes
   de añadirlos (verificado: la lista de contact points estaba vacía).

| | Mimir ruler (`mimir-rules/`) | Grafana-managed (aquí) |
|---|---|---|
| Formato | reglas Prometheus (`namespace:` + `groups:`) | provisioning de Grafana (`apiVersion: 1`) |
| Despliegue | `mimirtool rules sync` desde CI | API de provisioning de Grafana (ver abajo) |
| Puede consultar | solo el tenant propio | cualquier datasource del stack |
| Expresa | evaluación (recording rules + alertas) | evaluación multi-datasource **y** entrega |

**Importante:** `mimirtool rules sync` **no toca** estos ficheros. Son dos mundos separados a
propósito; no mezcles los ficheros de directorio o el sync fallará al parsear.

## Cómo se aplican

Este directorio ya no se aplica a mano: **lo aplican los propios workflows de sync**
(`sync-alert-rules-dev.yml` / `sync-alert-rules-prod.yml`), en un tramo posterior al sync de
mimirtool que ejecuta `.github/scripts/apply-grafana-provisioning.ps1`. La lista de ficheros
está en su variable `PROVISIONING_FILES` (un fichero nuevo se lista en los dos workflows). El
tramo tiene su propio sub-gate: sin `GRAFANA_API_URL`, `VETSOFTWARE_ALERT_EMAIL` o
`GRAFANA_PROVISIONING_TOKEN` en el environment avisa y pasa, sin afectar al sync del ruler.
Dos semánticas que conviene tener presentes (detalle en
`docs/ALERTAS_GRAFANA_CLOUD.md`):

- Es un **upsert por `uid`**: crea y actualiza, pero no borra del stack lo que desaparezca
  de estos ficheros; retirar un recurso exige un `DELETE` manual.
- Antes de aplicar, el script **sustituye los marcadores `${NOMBRE}`** por variables de
  entorno (hoy `${VETSOFTWARE_ALERT_EMAIL}`) y **falla si alguno queda sin resolver** — un
  marcador literal guardado en Grafana parece configurado y no notifica a nadie. Los
  marcadores en líneas comentadas (el webhook de Slack) no exigen su variable todavía.

Grafana Cloud **no tiene provisioning por fichero** (no hay filesystem): estos YAML son la
fuente de verdad versionada, en el mismo formato que emiten los endpoints de export de la API
de provisioning, y el pipeline los traduce a llamadas HTTP. Cada tipo de recurso tiene su
endpoint y su forma:

| Recurso | Endpoint | Nota de forma |
|---|---|---|
| Alert rules | `POST /api/v1/provisioning/alert-rules` (crear) / `PUT .../alert-rules/<uid>` (actualizar) | una regla por llamada; el `interval` del grupo se fija aparte vía `PUT /api/v1/provisioning/folder/<uid>/rule-groups/<grupo>` |
| Contact points | `POST /api/v1/provisioning/contact-points` (crear) / `PUT .../contact-points/<uid>` (actualizar) | **un contact point por llamada**, sin el wrapper `contactPoints:` |
| Policy | `PUT /api/v1/provisioning/policies` | el árbol **sin** el wrapper `policies:`; **reemplaza el árbol completo**, incluido `grafana-default-email` |

Token: un **service account token** de la instancia de Grafana (`glsa_...`), cargado como
secret `GRAFANA_PROVISIONING_TOKEN`. **No sirve un token de Access Policy del portal**: se
comprobó en vivo (2026-08-18) que la API de la instancia rechaza el `glc_` del ruler como
clave (`api-key.invalid`), no por falta de scopes — son dos planos de credencial distintos.
Cómo crearlo, en `docs/ALERTAS_GRAFANA_CLOUD.md`. El pipeline **no** envía
`X-Disable-Provenance`, así que los recursos quedan marcados como provisionados y de solo
lectura en la UI — que es lo correcto cuando el pipeline es la única vía de cambio.

Requisitos previos que la API no crea sola:

- La carpeta `VetSoftware` debe existir en el stack (la referencia `folder:` de la cost-guard).
- El webhook de Slack **no existe todavía** y solo puede crearlo una persona con permisos en
  el workspace `T0BMM8Y0FC5`; los IDs de canal conocidos (`C0BNT7FCWSH`, `C0BNWM8ASAE`)
  pertenecen a la integración de AWS Chatbot, que Grafana no puede usar. El paso a paso está
  en la cabecera de `vetsoftware-contact-points.yml`. Mientras tanto, **el correo funciona
  desde el primer apply**: Grafana Cloud lo envía de forma nativa, sin credencial externa.

**Verificación pendiente tras el primer apply** (está detallada en la cabecera de la policy):
confirmar que las alertas del **ruler** entregan por este Alertmanager de Grafana. La
evidencia apunta a que sí (los stacks recientes de Grafana Cloud entregan ahí por defecto y
este stack no tiene datasource de Alertmanager de Mimir aparte), pero si una alerta del ruler
no llegara al correo, el ruler estaría entregando en el Alertmanager de Mimir del tenant y
habría que cargar allí una configuración equivalente con `mimirtool alertmanager load`.

## Qué vigila la cost-guard y por qué importa

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
ella la capacidad de ver cualquier otro incidente — incluidas las 24 alertas del ruler, que
dejarían de tener datos que evaluar. De ahí que sea la alerta que protege a todas las demás.

Otro límite del mismo bloque, que conviene tener presente aunque no tenga alerta:
**`ruler_max_rule_groups_per_tenant` = 85**, y los ficheros de `mimir-rules/` usan 18 grupos
en dev (19 con el heartbeat de prod). Hay margen, pero no es infinito.
