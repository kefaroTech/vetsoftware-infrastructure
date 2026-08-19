# Alertas en Grafana Cloud: reglas del ruler de Mimir y su sincronización

El backend exporta métricas por OTLP a Grafana Cloud
([Telemetría OTLP](TELEMETRIA_OTLP.md)). Las reglas que evalúan esas métricas
—grabación de SLO y alertas de plataforma— viven en este repositorio,
en `observability/mimir-rules/`, y un mecanismo de CI las sincroniza al ruler de
Mimir del stack. Los mismos workflows aplican además, por la API de
provisioning de Grafana, lo que no puede vivir en el ruler: los contact
points, la notification policy y las alertas Grafana-managed de
`observability/grafana-managed/`. Este documento describe el mecanismo
completo, con sus dos tramos.

## Por qué las reglas viven en este repositorio y no en el backend

Podría argumentarse que una alerta sobre métricas de la aplicación pertenece al
repositorio de la aplicación. Pesa más lo contrario:

- **La maquinaria de telemetría ya está aquí.** El endpoint OTLP canónico, su
  verificador, el envío de logs por Firehose y las alarmas CloudWatch son de
  este repositorio. Las reglas de Mimir son la otra mitad de la misma
  observabilidad.
- **Los environments con aprobación viven aquí.** `iac-apply-dev` e
  `iac-apply-prod` ya existen, ya tienen deployment branch policies y ya
  custodian credenciales de despliegue. Sincronizar reglas es un despliegue:
  usa el mismo control sin duplicarlo en otro repositorio.
- **El ciclo de cambio es el de infraestructura.** Una alerta se ajusta con la
  vista puesta en la topología (una `db.t4g.micro` que entra en crash loop, un
  apagado programado a las 20:00), no en el código Java.

## Los ficheros y a qué ambiente van

**El ruler solo tiene recording rules. Todas las alertas son Grafana-managed.**

Formato mimirtool (`namespace:` + `groups:`), sincronizado con `mimirtool rules sync`:

| Fichero (`observability/mimir-rules/`) | dev | prod |
|---|---|---|
| `vetsoftware-slo-rules.yml` — 57 recording rules | sí | sí |

Las 25 alertas vivieron aquí y se movieron, porque **en el ruler no notificaban a nadie**.
Grafana Cloud tiene dos motores de alertas con dos Alertmanager que no se hablan entre sí, y
el de Mimir no está expuesto en el plan Free. Verificado en vivo el 2026-08-19: 10 alertas
disparando en el ruler y `/api/alertmanager/grafana/api/v2/alerts` devolviendo `[]`.

Las recording rules se quedan porque no necesitan Alertmanager — solo calculan series —, y
las alertas convertidas las leen por el datasource `grafanacloud-prom`, que apunta al mismo
tenant: la cadena SLO sigue entera, solo cambia quién evalúa el último escalón.

**Regla práctica al añadir algo:** recording rule → `mimir-rules/`; alerta →
`grafana-managed/`. Una alerta puesta en `mimir-rules/` evalúa y no notifica, en silencio —
que es el fallo que costó descubrir.

El directorio `observability/grafana-managed/` **`mimirtool` no lo toca**: lo aplican los
mismos workflows en un tramo posterior, por la **API de provisioning de Grafana** (ver «El
flujo»). El workflow de calidad del PR tampoco lo valida, porque sus globs apuntan a
`mimir-rules/`.

| Fichero (`observability/grafana-managed/`) | Qué es |
|---|---|
| `vetsoftware-contact-points.yml` | Receptores de notificación (`contactPoints:`) |
| `vetsoftware-notification-policy.yml` | Árbol de enrutamiento (`policies:`) |
| `vetsoftware-slo-alerts-managed.yml` | 6 alertas SLO |
| `vetsoftware-platform-alerts-managed.yml` | 11 de plataforma (HTTP, JVM, HikariCP, tokens) |
| `vetsoftware-cloud-additions-managed.yml` | 7: jobs, correo, abuso de login, Valkey |
| `vetsoftware-cost-guard.yml` | 1: guarda de ingesta |
| `vetsoftware-heartbeat-prod-managed.yml` | 1: ausencia de ingesta — **solo prod** |

La lista exacta está en la variable `PROVISIONING_FILES` de cada workflow de sync, con la
misma regla que `RULE_FILES`: **un fichero nuevo se añade en los dos workflows**.

Las listas exactas están en la variable `RULE_FILES` de cada workflow de sync.
**Un fichero común nuevo se añade en los dos**; el heartbeat, o cualquier otro
exclusivo de un ambiente, solo en el suyo. El workflow de calidad del PR valida
todo `*.yml` del directorio sin lista, así que un fichero olvidado en los syncs
se valida igualmente pero no llega al ruler: la revisión del PR debe mirar
`RULE_FILES` cuando aparezca un fichero nuevo.

## El flujo

```
PR que toca observability/mimir-rules/**
  └─ alert-rules-quality.yml  → mimirtool rules lint --dry-run + rules check
                                 (local, sin credenciales, sin acceso remoto)
merge a develop
  └─ sync-alert-rules-dev.yml (push, environment iac-apply-dev)
       ── tramo ruler ──────────────────────────────────────────────
       gate → paridad canónica → lint/check → diff (informativo) → sync
       ── tramo provisioning de Grafana ────────────────────────────
       sub-gate (GRAFANA_API_URL) → paridad canónica de la API
         → apply-grafana-provisioning.ps1 (contact points →
           notification policy → reglas Grafana-managed)

workflow_dispatch desde main
  └─ sync-alert-rules-prod.yml (environment iac-apply-prod, patrón authorize-ref)
       mismos tramos, con el heartbeat añadido al ruler
```

- **dev sincroniza en cada push a `develop`** que toque las reglas. Es el
  ambiente de integración: la regla mergeada es la regla evaluándose.
- **prod solo por `workflow_dispatch` desde `refs/heads/main`**, con la
  aprobación del environment `iac-apply-prod`. Igual que `terraform-apply-prod`:
  alguien lo decide, alguien lo aprueba, queda registrado.
- **La validación del PR es local a propósito.** Un PR ejecuta código de una
  rama arbitraria; no debe ver el token del ruler. No se usa `promtool`: habría
  que extraer los `groups:` de debajo de `namespace:` con una herramienta
  extra, y `mimirtool` ya parsea el YAML y cada expresión PromQL con el parser
  embebido de Prometheus.

### El repositorio manda: sync borra

`mimirtool rules sync` deja el tenant exactamente como los ficheros enviados:
crea lo que falta, actualiza lo que cambió y **borra lo que sobra**. Una regla
creada a mano en la consola de Grafana Cloud desaparece en el siguiente sync.
Eso es deliberado —es lo que convierte el directorio en la fuente de verdad—,
pero hay que saberlo antes de tocar nada por consola. El paso de `diff` previo
deja en el log del workflow qué se va a crear, cambiar y borrar.

Nota de alcance: esto gobierna las reglas del **ruler de Mimir** (formato
Prometheus). Las alertas *Grafana-managed*, los contact points y la
notification policy van por el tramo de provisioning, que tiene **la semántica
contraria**:

### El tramo de provisioning NO borra: es un upsert

`apply-grafana-provisioning.ps1` convierte los ficheros `apiVersion: 1` de
`observability/grafana-managed/` en llamadas JSON a
`/api/v1/provisioning/...` y hace *upsert* por `uid`: crea lo que falta y
actualiza lo que cambió, pero **no borra del stack lo que desaparezca del
repositorio**. Retirar un contact point o una regla Grafana-managed exige un
`DELETE` manual contra la API (o desde la UI, si el objeto no tiene
provenance). Es una asimetría deliberada frente a `mimirtool rules sync`:
borrar «todo lo que no esté en los ficheros» exigiría enumerar y comparar el
stack entero en cada ejecución, y un error de lista arrasaría receptores en
producción. A cambio, los objetos se aplican **con provenance** (sin
`X-Disable-Provenance`), así que Grafana bloquea su edición en la UI y el
repositorio sigue siendo la fuente de verdad para lo que declara.

### mimirtool anclado por versión y checksum

Los tres workflows instalan el mismo binario de release
(`mimir-3.1.4`, `mimirtool-linux-amd64`, publicado 2026-07-22) y verifican su
SHA-256 antes de ejecutarlo. Sin action de terceros y sin `latest`: lo que
valida el PR es byte a byte lo que después sincroniza, y una release
comprometida aguas arriba no entra sin cambiar el checksum en un diff revisable.
Para subir de versión: cambiar `MIMIR_RELEASE` y `MIMIRTOOL_SHA256` en los tres
workflows a la vez, tomando el checksum del asset `mimirtool-linux-amd64-sha-256`
de la release.

## Credenciales y variables

Convención idéntica en los dos environments. Estado actual: **los tres valores
del ruler de dev ya están cargados y funcionando** en `iac-apply-dev`; faltan
los tres del tramo de provisioning (`GRAFANA_API_URL`,
`VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL` y `GRAFANA_PROVISIONING_TOKEN`), y
todo lo de prod hasta que exista su stack.

| Dónde | Tipo | Nombre | Valor | Estado |
|---|---|---|---|---|
| environment `iac-apply-dev` | variable | `GRAFANA_RULER_URL` | Host del ruler del stack de dev (ver abajo) | cargada |
| environment `iac-apply-dev` | variable | `GRAFANA_METRICS_TENANT_ID` | Instance ID numérico de Prometheus del stack de dev | cargada |
| environment `iac-apply-dev` | secret | `GRAFANA_RULER_TOKEN` | Token de Access Policy con `rules:read` + `rules:write` | cargado |
| environment `iac-apply-dev` | variable | `GRAFANA_API_URL` | `https://vastcoyote3439.grafana.net` (host de la instancia de Grafana, ver abajo) | **pendiente** |
| environment `iac-apply-dev` | secret | `VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL` | Webhook entrante de Slack para las notificaciones (secreto, no variable: quien tenga la URL puede publicar en el canal) | **pendiente** |
| environment `iac-apply-dev` | secret | `GRAFANA_PROVISIONING_TOKEN` | **Service account token** de la instancia (`glsa_...`, ver abajo) — NO un token de Access Policy | **pendiente** |
| environment `iac-apply-prod` | variable | `GRAFANA_RULER_URL` | Ídem, del stack de prod (aún no existe) | pendiente |
| environment `iac-apply-prod` | variable | `GRAFANA_METRICS_TENANT_ID` | Ídem, del stack de prod | pendiente |
| environment `iac-apply-prod` | secret | `GRAFANA_RULER_TOKEN` | Ídem, del stack de prod | pendiente |
| environment `iac-apply-prod` | variable | `GRAFANA_API_URL` | `https://<stack-prod>.grafana.net` | pendiente |
| environment `iac-apply-prod` | secret | `VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL` | Ídem (puede ser otro webhook, hacia otro canal, que el de dev) | pendiente |
| environment `iac-apply-prod` | secret | `GRAFANA_PROVISIONING_TOKEN` | Ídem, de la instancia de prod | pendiente |

De dónde sale cada valor, en Grafana Cloud:

1. **`GRAFANA_RULER_URL`**: portal de Grafana Cloud → stack (`vastcoyote3439`
   para dev) → tarjeta **Prometheus** → *Details* → **Query Endpoint**. La URL
   del ruler es ese host, por ejemplo
   `https://prometheus-prod-XX-prod-us-east-3.grafana.net`, sin path.
2. **`GRAFANA_METRICS_TENANT_ID`**: en la misma tarjeta, el **Instance ID**
   numérico (el *username* de Prometheus). `mimirtool` lo usa como `--id`.
3. **`GRAFANA_RULER_TOKEN`**: portal → *Access Policies* → crear una política
   con los scopes **`rules:read`** y **`rules:write`** (categoría
   Alerts/Rules), restringida al stack, y generar un token. Es un secreto:
   nunca en un `.tf` ni en un tfvars commiteado
   ([Gestión de secretos](GESTION_DE_SECRETOS.md)).
4. **`GRAFANA_API_URL`**: el host de la **instancia de Grafana** del stack,
   `https://<nombre-del-stack>.grafana.net` (para dev,
   `https://vastcoyote3439.grafana.net`; se ve en el portal → stack → tarjeta
   **Grafana** → *Launch*). No confundir con `GRAFANA_RULER_URL`: aquel es el
   host de Mimir/Prometheus, este el de la UI y de la API de provisioning.
5. **`GRAFANA_PROVISIONING_TOKEN`**: un **service account token** creado
   **dentro de la instancia de Grafana**, no en el portal: abrir
   `GRAFANA_API_URL` → *Administration → Users and access → Service
   accounts* → *Add service account* → rol con permisos de alerting (Editor
   sirve; con RBAC granular, los permisos de *Alerting: rules* y *Alerting:
   notifications* de escritura) → *Add service account token* → copiar el
   `glsa_...`. Es un secreto: nunca en un `.tf` ni en un tfvars commiteado
   ([Gestión de secretos](GESTION_DE_SECRETOS.md)). Hasta que exista y sea
   válido, el tramo de provisioning detecta el `401/403`, lo anota como
   *warning* y pasa sin fallar.
6. **`VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL`**: un **webhook entrante de
   Slack**, que hoy no existe y hay que crear:
   [https://api.slack.com/apps](https://api.slack.com/apps) → *Create New
   App* (workspace `T0BMM8Y0FC5`) → *Incoming Webhooks* → activar → *Add New
   Webhook to Workspace* → **elegir el canal**. Dos cosas que hay que saber:
   - **El canal se decide en Slack, no en el fichero**: el webhook queda
     ligado al canal elegido al crearlo. Hoy critical y warning comparten
     webhook (y por tanto canal); para separarlos en canales distintos harían
     falta **dos** webhooks, uno por contact point.
   - **La conexión de Slack que el proyecto ya tiene NO sirve.** Los canales
     existentes (`C0BNT7FCWSH` alertas, `C0BNWM8ASAE` infra, workspace
     `T0BMM8Y0FC5`) pertenecen a la integración de **AWS Chatbot**, y Grafana
     no puede usarla: necesita su propio webhook. Es la confusión natural —
     «ya tengo Slack conectado, ¿por qué otro webhook?» — y la respuesta es
     que aquel webhook es de AWS, no nuestro.

   El fichero de contact points versiona el marcador
   `${VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL}`, nunca la URL; el script la
   sustituye desde el secret en el momento de aplicar y **falla si el
   marcador queda sin resolver**, porque un literal `${...}` guardado en
   Grafana parece configurado y no notifica a nadie.

### El respaldo por correo, documentado y desactivado

`vetsoftware-contact-points.yml` conserva la integración de correo
**comentada** en los dos contact points. El riesgo que cubriría está escrito
en su cabecera y conviene repetirlo: con Slack como **único canal de
entrega**, si el webhook se revoca o el canal se archiva, las alertas dejan de
notificar **en silencio** — siguen disparando en la UI de Grafana y nadie se
entera. Para activar el respaldo: descomentar las dos integraciones de correo
en el fichero y volver a añadir `VETSOFTWARE_ALERT_EMAIL` (variable de
environment) al sub-gate de los dos workflows, para que el marcador tenga con
qué resolverse.

### Dos tipos de credencial que no son intercambiables

La confusión ya ocurrió una vez, así que queda escrita. Grafana Cloud tiene
**dos planos de autenticación**:

- **Token de Access Policy** (portal → *Access Policies*, prefijo `glc_`):
  autentica el **plano de datos** — Mimir, Loki, Tempo — acompañado del
  Instance ID (`--id` en `mimirtool`). Es lo que usa `GRAFANA_RULER_TOKEN`.
- **Service account token** (dentro de la instancia, prefijo `glsa_`):
  autentica la **API de la instancia de Grafana** (`/api/...`), incluida la de
  provisioning de alertas. Es lo que usa `GRAFANA_PROVISIONING_TOKEN`.

Verificado en vivo (2026-08-18) contra `vastcoyote3439.grafana.net`: con el
token `glc_` del ruler, `/api/v1/provisioning/*` responde
`401 {"messageId":"api-key.invalid"}` — rechazado **como clave**, no por falta
de scopes —, mientras que sin token responde
`401 {"messageId":"auth.unauthorized"}`. No sirve ampliar la Access Policy
del ruler: hace falta la otra credencial.

Al cargar las variables de dev en GitHub hay que fijar **en el mismo cambio**
los campos correspondientes (`ruler_url`, `metrics_tenant_id`,
`grafana_api_url`) en `.github/telemetry-endpoints.json`; si no, el
verificador de paridad no vigila nada (ver siguiente sección). Los del ruler
de dev ya están fijados; `grafana_api_url` de dev también, así que en cuanto
la variable se cargue el guardarraíl la vigila.

## El guardarraíl canónico

El mismo patrón que el endpoint OTLP, y por el mismo motivo: las variables de
GitHub no pasan por revisión de PR, el manifiesto versionado sí.

- `.github/telemetry-endpoints.json` lleva `ruler_url`, `metrics_tenant_id` y
  `grafana_api_url` por ambiente (los de prod, `null` con nota).
- `.github/scripts/assert-ruler-endpoint.ps1` —hermano de
  `assert-telemetry-endpoint.ps1`, script aparte para no arriesgar los nueve
  call sites del original— compara las variables del environment contra el
  manifiesto **antes de que el job toque el token**:
  - no coinciden → error y `exit 1`;
  - canónico `null` → *warning* y pasa;
  - la barra final de la URL no distingue dos valores.
- `.github/scripts/assert-grafana-api-endpoint.ps1`, tercer hermano con la
  misma semántica, vigila `GRAFANA_API_URL` contra `grafana_api_url`. Es un
  script aparte y corre **después** del sync del ruler a propósito: su
  mismatch debe cortar solo el tramo de provisioning (poniendo el job en
  rojo), no impedir que las reglas lleguen al ruler.

## Modo «avisa y pasa»

Si `GRAFANA_RULER_URL` o `GRAFANA_METRICS_TENANT_ID` están vacíos en el
environment, el job de sync lo anota como *warning*, lo escribe en el summary y
**termina en verde sin sincronizar**. Es el mismo comportamiento que el
verificador OTLP tiene para prod sin stack: fallar bloquearía cada merge a
`develop` por una configuración que todavía no se ha cargado. Prod arrancará
así hasta que exista su stack. El día que se carguen los valores, el mismo
workflow empieza a sincronizar sin tocar una línea.

El tramo de provisioning tiene su **propio sub-gate** con la misma filosofía,
en dos niveles:

- `GRAFANA_API_URL` vacía, o los secrets
  `VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL` / `GRAFANA_PROVISIONING_TOKEN`
  ausentes → el sub-gate anota el *warning* y omite el tramo entero; el sync
  del ruler **no se ve afectado**. Es un gate separado adrede: si estas
  condiciones entraran en el gate principal, su ausencia apagaría también el
  sync de mimirtool, que ya funciona y no depende de ellas. Los dos secretos
  se comprueban con el mismo patrón booleano que el gate principal
  (`secrets.X != ''`), sin materializar su valor en el runner; el webhook
  además se inyecta **solo en el paso del apply**, no en el `env:` del job
  entero.
- Todo cargado pero el token no vale (por ejemplo, se cargó un `glc_` de
  Access Policy en vez del `glsa_` de service account) → la API devuelve
  `401/403` y `apply-grafana-provisioning.ps1` lo convierte en *warning* y
  `exit 0`, indicando qué alcanzó a aplicarse antes del corte. La
  contrapartida asumida: un `403` real (token revocado, rol recortado)
  también saldrá amarillo y no rojo, así que el summary del job es lo que hay
  que mirar tras cargar el token.
- **Excepción que sí es roja siempre**: un marcador `${...}` sin resolver en
  los ficheros. Enviarlo literal a Grafana es un fallo silencioso (queda
  guardado y parece configurado), así que el script corta con error aunque
  el resto del tramo esté en modo avisa-y-pasa.

## Relación con las alarmas CloudWatch de `log_shipping`

Son complementarias, no redundantes:

- Las **alarmas CloudWatch** del módulo `log_shipping` vigilan el **transporte**
  del lado AWS: que Firehose entregue los logs a Grafana Cloud. Si el camión no
  llega, suena CloudWatch ([Alertas operativas](ALERTAS_OPERATIVAS.md)).
- Las **reglas de Mimir** vigilan la **señal de la aplicación** ya dentro de
  Grafana Cloud: SLOs, plataforma, jobs y correo. Si el camión llega pero
  la carga dice que algo va mal, suena Mimir.

Un fallo total del transporte deja además a Mimir sin datos frescos, que es lo
que el heartbeat de prod está pensado para detectar desde el otro extremo.

## La notificación: cubierta por el tramo de provisioning

Los contact points y la notification policy viven versionados en
`observability/grafana-managed/` y los aplica el tramo de provisioning de los
mismos workflows de sync. Para que las alertas notifiquen de verdad hacen
falta, en este orden:

1. `GRAFANA_API_URL` cargada y el webhook entrante de Slack creado y cargado
   como secret `VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL` (tabla de credenciales
   y paso 6 — ojo: el Slack de AWS Chatbot no sirve).
2. El service account token creado en la instancia y cargado como
   `GRAFANA_PROVISIONING_TOKEN` (paso 5 de la misma sección — **no** es el
   token del ruler ni sale de Access Policies).
La carpeta `VetSoftware` **no hay que crearla a mano**: las reglas
Grafana-managed la referencian por nombre y el script la resuelve, creándola si
no existe. Es un contenedor vacío, no configuración, y exigir un paso previo en
la UI dejaría el pipeline sin ser autosuficiente — un stack nuevo (prod, o dev
recreado) fallaría su primer apply por algo que la máquina sabe hacer sola.

### Verificación pendiente de la primera ejecución real

Las rutas y payloads que usa `apply-grafana-provisioning.ps1`
(`/api/v1/provisioning/contact-points`, `/api/v1/provisioning/policies`,
`/api/v1/provisioning/alert-rules`, `/api/v1/provisioning/folder/<uid>/rule-groups/<grupo>`)
siguen la documentación de la *Alerting Provisioning HTTP API* de Grafana, pero
**no pudieron verificarse contra el stack**: `vastcoyote3439` responde `401`
antes de rutear (una ruta inventada también da `401`, tanto sin credenciales
como con el token del ruler), así que el único hecho comprobado es el host
(`/api/health` → `200`, Grafana 13.2.0). La primera ejecución con un service
account token válido es la prueba real; los puntos de más riesgo están
marcados con `INCIERTO:` en el propio script.

## Verificación manual en local

```powershell
# Validación local, la misma del PR (mimirtool para Windows: asset
# mimirtool-windows-amd64.exe de la release mimir-3.1.4):
mimirtool rules lint --dry-run (Get-ChildItem observability/mimir-rules/*.yml).FullName
mimirtool rules check (Get-ChildItem observability/mimir-rules/*.yml).FullName

# El verificador de paridad, sobre valores cualesquiera:
./.github/scripts/assert-ruler-endpoint.ps1 -Environment dev `
  -RulerUrl "https://prometheus-prod-XX-prod-us-east-3.grafana.net" -TenantId "123456"
$LASTEXITCODE

# Qué hay hoy en el ruler (requiere credenciales reales):
$env:MIMIR_API_KEY = "<token>"
mimirtool rules list --address="<GRAFANA_RULER_URL>" --id="<GRAFANA_METRICS_TENANT_ID>"
```
