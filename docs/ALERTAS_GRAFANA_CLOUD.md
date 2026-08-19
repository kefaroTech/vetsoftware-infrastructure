# Alertas en Grafana Cloud: reglas del ruler de Mimir y su sincronización

El backend exporta métricas por OTLP a Grafana Cloud
([Telemetría OTLP](TELEMETRIA_OTLP.md)). Las reglas que evalúan esas métricas
—grabación de SLO y alertas de plataforma— viven en este repositorio,
en `observability/mimir-rules/`, y un mecanismo de CI las sincroniza al ruler de
Mimir del stack. Este documento describe ese mecanismo completo.

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

Hay además un directorio hermano, `observability/grafana-managed/`, que **este mecanismo no
toca**. Contiene la guarda de ingesta, que no puede ser una regla del ruler porque consulta
métricas de uso alojadas en otro tenant (`grafanacloud-usage`). Tiene su propio README con el
porqué y cómo aplicarla; `mimirtool` ni la ve, y el workflow de calidad tampoco, porque todos
los globs apuntan a `mimir-rules/`.

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
       gate → paridad canónica → lint/check → diff (informativo) → sync

workflow_dispatch desde main
  └─ sync-alert-rules-prod.yml (environment iac-apply-prod, patrón authorize-ref)
       mismos pasos, con el heartbeat añadido
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
Prometheus). Las alertas *Grafana-managed*, si algún día existieran, viven en
otro sistema y no las toca.

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

Convención idéntica en los dos environments. **Ninguno de estos valores existe
todavía en GitHub**: cargarlos es un paso manual del usuario.

| Dónde | Tipo | Nombre | Valor |
|---|---|---|---|
| environment `iac-apply-dev` | variable | `GRAFANA_RULER_URL` | Host del ruler del stack de dev (ver abajo) |
| environment `iac-apply-dev` | variable | `GRAFANA_METRICS_TENANT_ID` | Instance ID numérico de Prometheus del stack de dev |
| environment `iac-apply-dev` | secret | `GRAFANA_RULER_TOKEN` | Token de Access Policy con `rules:read` + `rules:write` |
| environment `iac-apply-prod` | variable | `GRAFANA_RULER_URL` | Ídem, del stack de prod (aún no existe) |
| environment `iac-apply-prod` | variable | `GRAFANA_METRICS_TENANT_ID` | Ídem, del stack de prod |
| environment `iac-apply-prod` | secret | `GRAFANA_RULER_TOKEN` | Ídem, del stack de prod |

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

Al cargar las variables de dev en GitHub hay que fijar **en el mismo cambio**
los campos `ruler_url` y `metrics_tenant_id` de dev en
`.github/telemetry-endpoints.json`; si no, el verificador de paridad no vigila
nada (ver siguiente sección).

## El guardarraíl canónico

El mismo patrón que el endpoint OTLP, y por el mismo motivo: las variables de
GitHub no pasan por revisión de PR, el manifiesto versionado sí.

- `.github/telemetry-endpoints.json` lleva ahora `ruler_url` y
  `metrics_tenant_id` por ambiente (hoy `null` en los dos, con nota).
- `.github/scripts/assert-ruler-endpoint.ps1` —hermano de
  `assert-telemetry-endpoint.ps1`, script aparte para no arriesgar los nueve
  call sites del original— compara las variables del environment contra el
  manifiesto **antes de que el job toque el token**:
  - no coinciden → error y `exit 1`;
  - canónico `null` → *warning* y pasa;
  - la barra final de la URL no distingue dos valores.

## Modo «avisa y pasa»

Si `GRAFANA_RULER_URL` o `GRAFANA_METRICS_TENANT_ID` están vacíos en el
environment, el job de sync lo anota como *warning*, lo escribe en el summary y
**termina en verde sin sincronizar**. Es el mismo comportamiento que el
verificador OTLP tiene para prod sin stack: fallar bloquearía cada merge a
`develop` por una configuración que todavía no se ha cargado. Prod arrancará
así hasta que exista su stack; dev también, hasta que el usuario cargue los
valores de la tabla anterior. El día que se carguen, el mismo workflow empieza
a sincronizar sin tocar una línea.

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

## Lo que este trabajo NO cubre: la notificación

Los **contact points y la notification policy del Alertmanager de Grafana
Cloud están sin configurar**. Con lo descrito aquí, las reglas se evalúan y las
alertas disparadas se ven en la UI de Grafana (*Alerting → Alert rules /
Firing*), pero **no notifican a nadie**: no hay correo, ni Slack, ni webhook
hasta que el usuario decida receptor y lo configure en el Alertmanager del
stack (o se automatice después, por ejemplo con `mimirtool alertmanager` y un
fichero de configuración versionado). Es el paso pendiente explícito de este
mecanismo.

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
