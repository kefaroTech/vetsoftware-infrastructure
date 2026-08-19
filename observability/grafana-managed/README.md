# Alerting Grafana-managed

**Aquí vive TODO el alerting del proyecto**: las 26 alertas y su configuración de entrega.
En `../mimir-rules/` solo quedan recording rules.

| Fichero | Qué es | Ambientes |
|---|---|---|
| `vetsoftware-contact-points.yml` | 2 contact points (`vetsoftware-critical`, `vetsoftware-warning`), integración de Slack | dev y prod |
| `vetsoftware-notification-policy.yml` | El árbol de enrutado: raíz + una route por `severity` | dev y prod |
| `vetsoftware-slo-alerts-managed.yml` | 6 alertas SLO (3 de burn rate multiventana, 2 de budget, 1 de integridad) | dev y prod |
| `vetsoftware-platform-alerts-managed.yml` | 11 de plataforma (HTTP, JVM, HikariCP, tokens) | dev y prod |
| `vetsoftware-cloud-additions-managed.yml` | 7: jobs y correo (warning + critical cada una), abuso de login, Valkey ×2 | dev y prod |
| `vetsoftware-cost-guard.yml` | 1: `VetSoftwareIngestionNearLimit` | dev y prod |
| `vetsoftware-heartbeat-prod-managed.yml` | 1: ausencia de ingesta | **solo prod** |

## Por qué TODO está aquí y no en el ruler

Grafana Cloud tiene **dos motores de alertas**, cada uno con su propio Alertmanager, y **no
se hablan entre sí**. El del ruler de Mimir **no está expuesto en el plan Free**: no tiene
tarjeta en el portal, `mimirtool alertmanager get` responde «no Alertmanager config
currently exists» y `load` da 404 contra el host del ruler.

Verificado en vivo el 2026-08-19, con las alertas ya sincronizadas al ruler y los contact
points ya aplicados: **10 alertas disparando en el ruler y
`/api/alertmanager/grafana/api/v2/alerts` devolviendo `[]`**. Evaluaban perfectamente y no
notificaban a nadie. No era un fallo de Slack —el webhook respondía `200 ok`— sino de la
unión: reglas en un motor, receptores en el otro.

Como el Alertmanager de Mimir no se puede configurar y el de Grafana sí, las 25 alertas se
convirtieron a formato Grafana-managed. Es la decisión que unifica: **un motor, un
Alertmanager, una configuración de entrega, y todas las reglas visibles en la misma pantalla
de Alerting**.

Las 57 recording rules se quedan en el ruler porque no necesitan Alertmanager — solo
calculan series. Las alertas convertidas las leen por el datasource `grafanacloud-prom`, que
apunta al mismo tenant, así que la cadena SLO sigue entera.

Hay además una alerta que **nunca pudo estar en el ruler**: `cost-guard` consulta
`grafanacloud_instance_*` del datasource `grafanacloud-usage`, que es **otro tenant** y el
ruler solo alcanza el suyo. Fue la primera pista de que había dos mundos.

| | Mimir ruler (`mimir-rules/`) | Grafana-managed (aquí) |
|---|---|---|
| Formato | reglas Prometheus (`namespace:` + `groups:`) | provisioning de Grafana (`apiVersion: 1`) |
| Despliegue | `mimirtool rules sync` desde CI | API de provisioning de Grafana (ver abajo) |
| Puede consultar | solo el tenant propio | cualquier datasource del stack |
| Expresa | solo recording rules | evaluación multi-datasource **y** entrega |

**Importante:** `mimirtool rules sync` **no toca** estos ficheros. Son dos mundos separados a
propósito; no mezcles los ficheros de directorio o el sync fallará al parsear.

## Cómo se aplican

Este directorio ya no se aplica a mano: **lo aplican los propios workflows de sync**
(`sync-alert-rules-dev.yml` / `sync-alert-rules-prod.yml`), en un tramo posterior al sync de
mimirtool que ejecuta `.github/scripts/apply-grafana-provisioning.ps1`. La lista de ficheros
está en su variable `PROVISIONING_FILES` (un fichero nuevo se lista en los dos workflows). El
tramo tiene su propio sub-gate: sin `GRAFANA_API_URL`, el secret
`VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL` o el secret `GRAFANA_PROVISIONING_TOKEN` en el
environment avisa y pasa, sin afectar al sync del ruler.
Dos semánticas que conviene tener presentes (detalle en
`docs/ALERTAS_GRAFANA_CLOUD.md`):

- Es un **upsert por `uid`**: crea y actualiza, pero no borra del stack lo que desaparezca
  de estos ficheros; retirar un recurso exige un `DELETE` manual.
- Antes de aplicar, el script **sustituye los marcadores `${NOMBRE}`** por variables de
  entorno (hoy `${VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL}`, que el workflow inyecta solo en
  el paso del apply por ser un secreto) y **falla si alguno queda sin resolver** — un
  marcador literal guardado en Grafana parece configurado y no notifica a nadie. Los
  marcadores en líneas comentadas (el respaldo por correo, `${VETSOFTWARE_ALERT_EMAIL}`) no
  exigen su variable todavía.

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

- La carpeta `VetSoftware` (la referencia `folder:` de la cost-guard) **la crea el script si no
  existe**: es un contenedor vacío, no configuración, y pedir un paso manual previo dejaría el
  pipeline sin ser autosuficiente en un stack nuevo.
- El webhook de Slack es **bloqueante**: es la única integración activa de los contact
  points, y el sub-gate omite el tramo entero mientras el secret no esté cargado. Ya existe
  y está probado (`HTTP 200 · ok`) en el environment de dev. Solo puede crearlo una persona
  con permisos en el workspace `T0BMM8Y0FC5`; ojo con la trampa: los IDs de canal conocidos
  (`C0BNT7FCWSH`, `C0BNWM8ASAE`) pertenecen a la integración de **AWS Chatbot**, que Grafana
  no puede usar — el paso a paso está en la cabecera de `vetsoftware-contact-points.yml`. El
  correo queda **comentado como respaldo**: con un solo canal de entrega, un webhook revocado
  o un canal archivado deja las alertas sin notificar en silencio.

**La verificación que quedaba pendiente ya se hizo, y salió que no.** Se comprobó si las
alertas del ruler entregaban por este Alertmanager de Grafana: **no lo hacen**. Con 10
alertas disparando en el ruler, `/api/alertmanager/grafana/api/v2/alerts` devolvía `[]`. Esa
es la razón por la que las 25 alertas se convirtieron a Grafana-managed y hoy no queda
ninguna en el ruler — ver «Por qué TODO está aquí y no en el ruler», arriba.

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
ella la capacidad de ver cualquier otro incidente — incluidas las 26 alertas, que
dejarían de tener datos que evaluar. De ahí que sea la alerta que protege a todas las demás.

Otro límite del mismo bloque, que conviene tener presente aunque no tenga alerta:
**`ruler_max_rule_groups_per_tenant` = 85**, y `mimir-rules/` usa hoy 7 grupos, todos de
recording rules. Hay margen de sobra.
