# Reglas de Prometheus/Mimir para Grafana Cloud

Este directorio contiene los **gemelos cloud** de los ficheros de reglas locales de
`VetSoftware/docker/prometheus-*.yml`, en el formato que consume `mimirtool rules sync`
(cada fichero declara `namespace:` + `groups:`). Se evalúan en el **ruler de Mimir** del
stack de Grafana Cloud de cada ambiente, no en un Prometheus propio. La sincronización la
hacen los workflows del repo (fuera del alcance de este directorio).

| Fichero | Namespace | Contenido | Ambientes |
|---|---|---|---|
| `vetsoftware-slo-rules.yml` | `vetsoftware-slo-rules` | 57 recording rules SLO (cadena completa: objetivos → eventos 5m → ventanas → razones → burn rate → cumplimiento → budget) | dev y prod |
| `vetsoftware-slo-alerts.yml` | `vetsoftware-slo-alerts` | 6 alertas SLO (3 burn rate multiventana, 2 de budget, 1 de integridad) | dev y prod |
| `vetsoftware-platform-alerts.yml` | `vetsoftware-platform` | 11 alertas de plataforma portables (HTTP, JVM, HikariCP, tokens) | dev y prod |
| `vetsoftware-cloud-additions.yml` | `vetsoftware-additions` | 8 reglas: jobs y correo (warning + critical cada una), crash loop del proceso, abuso de login, y Valkey vía Lettuce (fallos + latencia) | dev y prod |
| `vetsoftware-heartbeat-prod.yml` | `vetsoftware-heartbeat` | 1 alerta de ausencia de ingesta | **solo prod** |

Los nombres de alerta, los `for:`, los labels `severity`/`domain`/`service` y las annotations
son los mismos que en local; los runbooks siguen apuntando a
`VetSoftware/docs/ALERTAMIENTO_OPERATIVO.md`.

## Por qué hay dos mundos de métricas

El stack local hace **scrape** de `/actuator/prometheus`; Grafana Cloud recibe las mismas
métricas por **OTLP push** (Micrometer → OTLP → Mimir). Son la misma fuente con dos
representaciones distintas, y por eso los ficheros locales y estos no son copia literal.
**Un cambio en un `docker/prometheus-*.yml` local debe evaluarse también aquí**, y viceversa
(cada fichero local lleva una cabecera que lo recuerda).

Tabla de traducción aplicada (verificada contra las series reales del stack de dev — no
re-derivarla, aplicarla):

| Local (scrape) | Cloud (OTLP push) |
|---|---|
| `http_server_requests_seconds_*` | `http_server_requests_milliseconds_*` (el max es `http_server_requests_max_milliseconds` — max ANTES de la unidad) |
| `vetsoftware_business_dian_transmission_duration_seconds_*` | `..._duration_milliseconds_*` |
| `tasks_scheduled_execution_seconds_*` | `tasks_scheduled_execution_milliseconds_*` |
| `email_send_template_seconds_*` | `email_send_template_milliseconds_*` |
| `job="vetsoftware"` | `job="mainvet/vetsoftware"` |
| `le="1.0"` / `le="2.0"` / `le="15.0"` | `le="1000"` / `le="2000"` / `le="15000"` — formato **entero**; `le="1000.0"` NO casa y el SLI desaparece en silencio |
| umbrales p95 > 1 / p99 > 2 (segundos) | > 1000 / > 2000 (milisegundos) |
| `jvm_threads_live_threads` | `jvm_threads_live` |
| resto de `jvm_*` / `process_*` / `hikaricp_*` / `vetsoftware_business_*` | idénticos (`vetsoftware_business_metrics_snapshot_age_seconds` es gauge y conserva `_seconds`) |

Bordes `le` reales publicados en cloud: HTTP `250, 500, 1000, 2000, 5000, 30000`;
DIAN duration `2000, 5000, 15000, 30000, 60000`. Un umbral de SLI **debe** coincidir con un
borde publicado; si se quiere otro umbral, primero se añade el borde en
`management.metrics.distribution.slo` del backend y después se toca la regla
(lo vigila `VetSoftwareSloSeriesAbsent`).

Labels de recurso presentes en todas las series cloud: `service_name="vetsoftware"`,
`deployment_environment_name` (`"dev"` hoy), `service_version`, `instance="ecs-fargate-spot"`.
Las reglas **no** filtran por environment a propósito: cada ambiente tiene (o tendrá) su
propio stack de Grafana Cloud, así que el aislamiento lo da el tenant, no un selector.

## Decisiones no mecánicas de la traducción

- **Intervalos de grupo 30 s → 1 m.** El ruler de Grafana Cloud trabaja cómodo a 1 m y, con
  el volumen real de dev (~0,42 req/s de export, ráfagas de uso), 30 s no compra nada. Los
  `for:` no cambiaron, así que el tiempo total hasta disparar crece como máximo ~30 s.
- **`job="mainvet/vetsoftware"` añadido donde el fichero local no lo llevaba**, como el
  bucket de latencia DIAN de la cadena SLO. En un tenant compartido el selector explícito
  es higiene, y deja toda la cadena coherente.
- **`VetSoftwareSecurityTokenTableGrowth` portada corregida**: `vetsoftware_security_tokens_rows`
  tiene `token_type` y `vetsoftware_security_tokens_growth_threshold` no; el original hacía
  `> on(job, instance)` sin `group_left()` y el match many-to-one **falla en runtime** (la
  alerta muere en silencio). Aquí: `> on(job, instance) group_left() ...`. La descripción
  conserva la referencia a `token_type`.
- **Variantes critical con `unless` en las alertas nuevas**: `fallos > 0 unless éxitos > 0`
  en lugar de `éxitos == 0`, porque si la serie de éxitos no existe en la ventana la
  comparación con `== 0` no casa con nada y la alerta nunca dispararía justo en el caso que
  debe cubrir (fallo total).
- **Un fichero, un `namespace`. No es una preferencia de estilo: mimirtool lo exige.**
  El primer intento dio a `vetsoftware-slo-rules.yml` y `vetsoftware-slo-alerts.yml` el mismo
  namespace `vetsoftware-slo`, suponiendo que la herramienta fusionaría dos ficheros con
  grupos disjuntos. No lo hace: aborta con
  `repeated namespace attempted to be loaded`, y el fallo lo destapó el CI porque
  `promtool` no puede verlo — se valida quitando justamente la clave `namespace:`.
  Al añadir un fichero, dale namespace propio y valida con `mimirtool`, no solo con
  `promtool`.

## Qué NO se portó y por qué

Estas alertas locales usan métricas que **no existen** en el mundo OTLP-push (verificado
contra el stack de dev):

| Alerta local | Motivo de exclusión |
|---|---|
| `VetSoftwareBackendDown` | usa `up`; no hay scrape en push OTLP. Sustituto prod: `vetsoftware-heartbeat-prod.yml`. |
| `VetSoftwareObservabilityTargetDown` | vigila contenedores del stack local (Loki/Tempo/Grafana/…); en cloud esos componentes son gestionados por Grafana Labs. |
| `VetSoftwareOtelLogExportFailing` | `otelcol_*` es telemetría interna del Collector local; en cloud no hay Collector propio en el camino de métricas. |
| `VetSoftwareOtelTraceExportFailing` | ídem `otelcol_*`. |
| `VetSoftwareOtelQueueDroppingTelemetry` | ídem `otelcol_*`. |
| `VetSoftwareOtelQueueNearCapacity` | ídem `otelcol_*`. |
| `VetSoftwareOtelReceiverRefusedTelemetry` | ídem `otelcol_*`. |
| `VetSoftwareLokiDiscardingLogs` | `loki_*` es meta-monitoring del Loki local; el Loki de cloud lo opera Grafana Labs. |
| `VetSoftwareLokiPanics` | ídem `loki_*`. |
| `VetSoftwareTempoDiscardingSpans` | `tempo_*` es meta-monitoring del Tempo local; en cloud es gestionado. |
| `VetSoftwareRedisDown` | `redis_*` viene del redis-exporter, que solo existe en local; el Valkey de dev no tiene exporter. **Cubierto por otra vía** — ver la nota de abajo. |
| `VetSoftwareRedisMemoryHigh` | ídem `redis_*`. Sin sustituto: la memoria del servidor solo la ve el exporter o CloudWatch/ElastiCache. |
| `VetSoftwareRedisRejectedConnections` | ídem `redis_*`. **Cubierto por otra vía** — ver la nota de abajo. |
| `VetSoftwareAlertmanagerNotificationFailures` | `alertmanager_*` es el Alertmanager local; la entrega en cloud es del Alertmanager gestionado del stack. |
| `VetSoftwarePrometheusRuleEvaluationFailures` | `prometheus_*` interna del Prometheus local; en cloud la evaluación es del ruler gestionado. |
| `VetSoftwarePrometheusNotificationFailures` | ídem `prometheus_*`. |

**Valkey sí quedó cubierto, por el lado del cliente.** La conclusión de que «no hay métricas de
Redis en cloud» era correcta sobre el *servidor* pero incompleta: el cliente **Lettuce está
instrumentado** y sus series llegan por OTLP (`lettuce_milliseconds_*`, con etiqueta `error`).
De ahí salen `VetSoftwareValkeyCommandsFailing` y `VetSoftwareValkeyLatencyHigh` en
`vetsoftware-cloud-additions.yml`. Lo que se ve desde el cliente —comandos que fallan, latencia
que sube— es además lo que de verdad afecta a la aplicación; lo que sigue sin verse es la
memoria interna del servidor, que es territorio de CloudWatch/ElastiCache.

**La salud del transporte de logs en cloud no queda huérfana**: el camino real es
stdout → CloudWatch → Firehose → Loki, y lo vigilan las alarmas CloudWatch de
`VetSoftwareIaC/modules/log_shipping/alarms.tf` del lado AWS (fallos de entrega de Firehose,
freshness, bucket de errores y el dead-man compuesto; no hay alarma dedicada de throttling).
Son capas **complementarias**, no duplicadas: Mimir vigila lo que la aplicación emite;
CloudWatch vigila el transporte que Mimir no puede ver.

### Las cuatro alertas de negocio: excluidas por decisión, no por imposibilidad

`VetSoftwareDianContingencyRateHigh`, `VetSoftwareDianBacklogOlderThanOneHour`,
`VetSoftwareInventoryInsufficientStockRateHigh` y `VetSoftwareBusinessMetricsSnapshotStale`
**sí eran portables** —sus métricas existen en cloud y llegaron a escribirse— pero el dueño
del producto decidió no vigilarlas por ahora. Se retiraron enteras: no queda fichero ni
namespace `vetsoftware-business`.

Esto no es un olvido y no debe "repararse" sin pedirlo: si algún día se quieren de vuelta,
siguen en `VetSoftware/docker/prometheus-business-alerts.yml` (versión local) y en el
historial de git de este directorio, y hay que volver a añadirlas a `RULE_FILES` en los dos
workflows de sync.

Lo que **sí** se conserva de ese dominio: el SLI `dian-transmission` de la cadena SLO sigue
vigilando la facturación electrónica por burn rate, y `VetSoftwareScheduledJobFailing` cubre
la reconciliación y la contingencia por el lado del job. La cobertura de DIAN baja, pero no
desaparece.

## Heartbeat: por qué es solo de prod

`vetsoftware-heartbeat-prod.yml` detecta la ausencia sostenida de ingesta
(`absent_over_time` sobre `target_info` **y** `jvm_threads_live` a la vez, para que un
renombre de una sola métrica no fabrique un falso "backend caído"). **No se sincroniza a
dev**: EventBridge apaga el ambiente de dev a las 20:00/20:15 de Bogotá de lunes a viernes y
los fines de semana completos, así que la alerta sonaría cada noche y sería ruido que
entrena a ignorar. El equivalente dev de "el backend no está" son los eventos del servicio
ECS del lado AWS, no el ruler.

## Advertencias de volumen (datos medidos en dev, 7 días)

- Dev tiene **~370 requests HTTP/7d** concentradas en horas de uso: las guardas de volumen
  de las alertas SLO (20 eventos/1h, 60/6h, 200/1d) **solo se cumplen en ráfagas de
  actividad**. Fuera de ráfagas, un fallo aislado no alcanzará a disparar burn rate — es la
  guarda funcionando, no una alerta rota.
- `VetSoftwareSloSeriesAbsent` **disparará legítimamente para la mayoría de SLIs la mayoría
  de los días** en dev: operaciones críticas que simplemente no se ejecutan en 24 h. En dev
  se silencia con vencimiento; en prod, un SLI sin tráfico 24 h sí merece explicación.
- `vetsoftware_business_inventory_movements_total` **no existe aún en cloud** (cero tráfico
  de inventario). El SLI `inventory-movement` queda inerte hasta el primer movimiento — es
  correcto, no un bug.
- DIAN en dev: **271 transmisiones/7d con 100 % error** (documento 44 atascado). Al activar
  estas reglas, las alertas de SLO de `dian-transmission` y
  `VetSoftwareScheduledJobFailing` dispararán de inmediato: es la señal correcta sobre un
  incidente real, no ruido.

Nada de lo anterior bloquea el despliegue de las reglas; es la expectativa honesta de qué se
verá el primer día.

## Coste en series

Las 57 recording rules producen como máximo ~300 series nuevas (10 pares `slo`/`sli` ×
{total, bad} × 7 ventanas ≈ 140; razones 7 × 10 = 70; burn rate 6 × 10 = 60; objetivo,
cumplimiento y budget 30), y en dev bastante menos porque los SLIs sin tráfico no materializan
serie. Las alertas añaden solo `ALERTS`/`ALERTS_FOR_STATE` mientras están pendientes o
activas. Irrelevante frente al límite del plan Free (10k series).

## Validación

`mimirtool rules lint --dry-run` + `mimirtool rules check` sobre este directorio — **es la
validación que manda**, y es la que corre el workflow de calidad del PR. En local, sin
instalar nada:

```bash
docker run --rm -v "$PWD:/rules" grafana/mimirtool:3.1.4 \
  rules lint --dry-run /rules/*.yml
docker run --rm -v "$PWD:/rules" grafana/mimirtool:3.1.4 \
  rules check /rules/*.yml
```

`promtool check rules` también sirve, pero **solo tras quitar la clave `namespace:`** (no la
conoce), y por eso mismo es ciego a los errores que viven en ese campo — el de namespace
repetido, sin ir más lejos. Úsalo como complemento, nunca como sustituto. Las pruebas unitarias de
reglas (`docker/tests/prometheus-*.test.yml` del backend) cubren la edición **local**; sus
series sintéticas usan nombres scrape (`_seconds_`) y no aplican tal cual a estos gemelos.
