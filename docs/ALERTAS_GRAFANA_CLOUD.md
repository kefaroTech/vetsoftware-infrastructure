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

Formato mimirtool: `namespace:` + `groups:` por fichero.

| Fichero (`observability/mimir-rules/`) | dev | prod |
|---|---|---|
| `vetsoftware-slo-rules.yml` | sí | sí |
| `vetsoftware-slo-alerts.yml` | sí | sí |
| `vetsoftware-platform-alerts.yml` | sí | sí |
| `vetsoftware-cloud-additions.yml` | sí | sí |
| `vetsoftware-heartbeat-prod.yml` | no | sí |

Hay además un directorio hermano, `observability/grafana-managed/`, que **`mimirtool` no
toca** pero que los mismos workflows de sync sí aplican, en un tramo posterior y por otra vía:
la **API de provisioning de Grafana** (ver «El flujo»). Contiene lo que no puede vivir en el
ruler: la guarda de ingesta (consulta métricas de uso alojadas en otro tenant,
`grafanacloud-usage`), los contact points y la notification policy del Alertmanager del stack.
Su README explica el porqué de la separación; el workflow de calidad del PR no los valida,
porque sus globs apuntan a `mimir-rules/`.

| Fichero (`observability/grafana-managed/`) | Qué es |
|---|---|
| `vetsoftware-contact-points.yml` | Receptores de notificación (`contactPoints:`) |
| `vetsoftware-notification-policy.yml` | Árbol de enrutamiento (`policies:`) |
| `vetsoftware-cost-guard.yml` | Alerta Grafana-managed de ingesta (`groups:`) |

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
`VETSOFTWARE_ALERT_EMAIL` y `GRAFANA_PROVISIONING_TOKEN`), y todo lo de prod
hasta que exista su stack.

| Dónde | Tipo | Nombre | Valor | Estado |
|---|---|---|---|---|
| environment `iac-apply-dev` | variable | `GRAFANA_RULER_URL` | Host del ruler del stack de dev (ver abajo) | cargada |
| environment `iac-apply-dev` | variable | `GRAFANA_METRICS_TENANT_ID` | Instance ID numérico de Prometheus del stack de dev | cargada |
| environment `iac-apply-dev` | secret | `GRAFANA_RULER_TOKEN` | Token de Access Policy con `rules:read` + `rules:write` | cargado |
| environment `iac-apply-dev` | variable | `GRAFANA_API_URL` | `https://vastcoyote3439.grafana.net` (host de la instancia de Grafana, ver abajo) | **pendiente** |
| environment `iac-apply-dev` | variable | `VETSOFTWARE_ALERT_EMAIL` | Correo destino de las notificaciones (variable, no secreto: es un destino, no una credencial) | **pendiente** |
| environment `iac-apply-dev` | secret | `GRAFANA_PROVISIONING_TOKEN` | **Service account token** de la instancia (`glsa_...`, ver abajo) — NO un token de Access Policy | **pendiente** |
| environment `iac-apply-prod` | variable | `GRAFANA_RULER_URL` | Ídem, del stack de prod (aún no existe) | pendiente |
| environment `iac-apply-prod` | variable | `GRAFANA_METRICS_TENANT_ID` | Ídem, del stack de prod | pendiente |
| environment `iac-apply-prod` | secret | `GRAFANA_RULER_TOKEN` | Ídem, del stack de prod | pendiente |
| environment `iac-apply-prod` | variable | `GRAFANA_API_URL` | `https://<stack-prod>.grafana.net` | pendiente |
| environment `iac-apply-prod` | variable | `VETSOFTWARE_ALERT_EMAIL` | Ídem (puede ser otro destino que el de dev) | pendiente |
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
6. **`VETSOFTWARE_ALERT_EMAIL`**: el buzón que debe recibir las
   notificaciones. El fichero de contact points versiona el marcador
   `${VETSOFTWARE_ALERT_EMAIL}` en lugar de una dirección personal; el script
   lo sustituye en el momento de aplicar y **falla si el marcador queda sin
   resolver**, porque un literal `${...}` guardado en Grafana parece
   configurado y no notifica a nadie.

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

- `GRAFANA_API_URL` o `VETSOFTWARE_ALERT_EMAIL` vacías, o
  `GRAFANA_PROVISIONING_TOKEN` ausente → el sub-gate anota el *warning* y
  omite el tramo entero; el sync del ruler **no se ve afectado**. Es un gate
  separado adrede: si estas condiciones entraran en el gate principal, su
  ausencia apagaría también el sync de mimirtool, que ya funciona y no
  depende de ellas. El token se comprueba con el mismo patrón booleano que el
  gate principal (`secrets.X != ''`), sin materializar el secreto en el
  runner.
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

1. `GRAFANA_API_URL` y `VETSOFTWARE_ALERT_EMAIL` cargadas en el environment
   (tabla de credenciales).
2. El service account token creado en la instancia y cargado como
   `GRAFANA_PROVISIONING_TOKEN` (paso 5 de la misma sección — **no** es el
   token del ruler ni sale de Access Policies).
3. La carpeta `VetSoftware` creada una vez en el stack (*Alerting → Alert
   rules → New folder*): las reglas Grafana-managed la referencian por nombre
   y el script la resuelve pero **no la crea**, para no pedir más permisos
   por un paso que ocurre una sola vez.

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
