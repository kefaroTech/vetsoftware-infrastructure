# Alertas operativas del entorno dev

Contrato de alertas de `vetsoftware-dev`: qué se vigila, con qué umbral, por qué
ese umbral y qué hacer cuando llega el mensaje a Slack.

Todo vive en `modules/monitoring` y se cablea desde `environments/dev/main.tf`.
El inventario en vivo se consulta con `terraform output alerting`.

---

## 1. Ruteo por tipo de señal

Cuatro topics, tres canales. La separación es por **tipo de señal** —una alarma
dice que algo está mal, un evento dice que algo pasó, un aviso de costo no exige
nada hoy— **salvo en los eventos, que se parten por severidad**. Cada familia
tiene su ritmo, y mezclarlas hace que la más frecuente entierre a la más
importante.

| Topic | Contenido | Canal |
| --- | --- | --- |
| `vetsoftware-dev-alarms` | alarmas de advertencia | alertas |
| `vetsoftware-dev-alarms-critical` | alarmas críticas y compuestas, **y los eventos que son incidentes** | alertas |
| `vetsoftware-dev-events` | despliegues, apagados y los eventos informativos de ECS y RDS | infra |
| `vetsoftware-dev-finops` | informe diario, presupuesto, anomalías | costos |

### Qué evento va a qué topic

Al principio salían **todos** los eventos por el topic de eventos, sin importar
su gravedad. El resultado era que un `🚨 evento critico de RDS` aterrizaba en el
canal de infra mientras una advertencia de reinicio de tarea —alarma, no evento—
llegaba al de alertas: la severidad quedaba invertida entre las dos familias. El
9 de agosto de 2026 eso importó, porque las dos notificaciones que llevaban la
causa raíz de un encendido fallido fueron a parar a infra.

| Evento | Topic | Por qué |
| --- | --- | --- |
| RDS crítico | crítico | La base está fuera de servicio o a punto |
| Tarea ECS detenida | crítico | Muere sin que nadie lo pidiera, y trae `stopCode` y `stoppedReason` |
| Scheduler sin capacidad | crítico | El servicio se queda sin tareas y nada lo sostiene |
| RDS advertencia | eventos | Conviene saberlo, no exige actuar |
| Despliegue revertido | eventos | El circuit breaker ya actuó: la versión anterior sigue sirviendo |

Como los eventos críticos publican en el topic crítico, **EventBridge está
autorizado en los dos topics**. Si faltara ese permiso, la regla casaría, el
target existiría y SNS rechazaría el `Publish`: la notificación desaparecería sin
error visible. Hay un contrato que lo fija.

La severidad sigue partida en dos topics aunque ambos vayan al mismo canal. No
cuesta nada y deja mandar lo crítico a una guardia más adelante con
`slack_critical_channel_id`, sin volver a repartir nada.

### Variables de canal

| Variable | Familia | Si está vacía |
| --- | --- | --- |
| `slack_channel_id` | costos, y todo lo que no tenga canal propio | deshabilita Slack |
| `slack_alerts_channel_id` | alarmas | cae al canal base |
| `slack_infra_channel_id` | eventos informativos | cae al canal base |
| `slack_critical_channel_id` | alarmas críticas y eventos que son incidentes | acompañan a las advertencias |

Configurar de menos nunca deja una señal sin destino: la manda al canal que ya
se estaba leyendo. Se crea **una configuración de Amazon Q por canal distinto**,
porque Amazon Q asocia la configuración al canal y dos apuntando al mismo se
pisan.

### Quién publica en cada topic

Esto es lo que hay que mirar cuando algo "no llegó":

| Topic | Publicadores |
| --- | --- |
| `-alarms`, `-alarms-critical` | `cloudwatch.amazonaws.com` |
| `-events` | `events.amazonaws.com`, los roles `iac-apply-dev` / `iac-plan-dev`, y el rol del scheduler de apagado |
| `-finops` | `budgets.amazonaws.com`, `costalerts.amazonaws.com`, la Lambda del informe de costos |

`dev-environment.ps1` deriva el ARN de `-events` por convención y hay que moverlo
si cambia el nombre; `backend-image.ps1` lee `events_topic_arn` del output
`alerting`. La Lambda del informe **recibe el ARN por variable de entorno** desde
Terraform, así que no depende de ninguna convención de nombres.

## 2. Backend en ECS Fargate

| Alarma | Señal | Umbral | Severidad |
| --- | --- | --- | --- |
| `backend-high-cpu` | `AWS/ECS CPUUtilization` | > 85 % · 2 de 2 × 5 min | advertencia |
| `backend-cpu-saturated` | `AWS/ECS CPUUtilization` | > 95 % · 3 de 3 × 5 min | crítico |
| `backend-high-memory` | `AWS/ECS MemoryUtilization` | > 85 % · 2 de 2 × 5 min | advertencia |
| `backend-memory-exhausted` | `MemoryUtilization` máximo | > 92 % · 3 de 5 × 1 min | crítico |
| `backend-task-restart` | `UnexpectedTaskStops` | ≥ 1 en 5 min | advertencia |
| `backend-crash-loop` | `UnexpectedTaskStops` | ≥ 3 en 15 min | crítico |
| `backend-spot-interruptions` | `SpotInterruptions` | ≥ 2 en 15 min | advertencia |
| `cloudflare-tunnel-errors` | errores del conector en logs | ≥ 1 en 5 min | crítico |
| `backend-degraded` (compuesta) | CPU alta **y** memoria alta | ambas en ALARM | crítico |

### Por qué 92 % de memoria

El backend arranca con `-XX:MaxRAMPercentage=70.0` y
`-XX:+ExitOnOutOfMemoryError`. Sobre los 2048 MiB de la tarea, el heap máximo
más metaspace, hilos y memoria directa aterrizan alrededor del 90 %. Pasado ese
punto el siguiente pico no lo absorbe el GC: lo mata el kernel. 92 % es el
último momento en que avisar sirve de algo.

La alarma crítica mide **máximos por minuto**, no promedios de cinco. Un OOM no
avisa diez minutos antes, y promediar cinco minutos suaviza exactamente el pico
que mata al contenedor.

### Por qué 3 paradas en 15 minutos

El health check del contenedor ya reintenta 3 veces cada 30 segundos antes de
declarar UNHEALTHY, y ECS entonces mata la tarea. Una parada suelta es ruido —una
tarea reemplazada—; tres en quince minutos es un servicio que no logra
sostenerse arriba. Cada ciclo fallido cuesta arranque de ENI, pull de imagen y
los 180 segundos de `startPeriod`, así que quince minutos dan cabida a tres
ciclos completos sin confundir un despliegue lento con un crash loop.

### De dónde sale `UnexpectedTaskStops`

ECS no publica una serie temporal de fallos de tarea, así que se construye:

```
EventBridge (toda parada de tarea del cluster)
  → log group /aws/events/vetsoftware-dev/ecs-task-state   (7 días)
    → filtro de métrica que excluye UserInitiated, ServiceSchedulerInitiated
      y SpotInterruption
      → métrica VetSoftware/Platform · UnexpectedTaskStops
        → alarmas M de N
```

Las exclusiones son la parte que importa. `UserInitiated` y
`ServiceSchedulerInitiated` son paradas pedidas —despliegues, escalado y el
apagado nocturno—, y contarlas convertiría cada noche en un crash loop.

El log group cumple además una segunda función: cuando una tarea muere se lleva
sus logs, y ese archivo conserva el `stoppedReason` exacto.

## 3. Base de datos RDS MySQL

| Alarma | Señal | Umbral | Severidad |
| --- | --- | --- | --- |
| `database-high-cpu` | `CPUUtilization` | > 80 % · 3 × 5 min | advertencia |
| `database-cpu-saturated` | `CPUUtilization` | > 95 % · 2 × 5 min | crítico |
| `database-connections-high` | `DatabaseConnections` | dev > 84 (70 % de 120) · prod > 42 (70 % de 60) | advertencia |
| `database-connections-exhausted` | `DatabaseConnections` | dev > 108 (90 % de 120) · prod > 54 (90 % de 60) | crítico |
| `database-low-storage` | `FreeStorageSpace` | < 5 GiB (25 %) | advertencia |
| `database-storage-exhausted` | `FreeStorageSpace` | < 2 GiB (10 %) | crítico |
| `database-low-memory` | `FreeableMemory` | < 256 MiB | advertencia |
| `database-memory-exhausted` | `FreeableMemory` mínimo | < 96 MiB · 3 de 5 × 1 min | crítico |
| `database-swap-usage` | `SwapUsage` | dev > 64 MiB · prod > 128 MiB · 15 min | advertencia |
| `database-read-latency` / `-write-latency` | `Read/WriteLatency` | > 20 ms · 15 min | advertencia |
| `database-disk-queue` | `DiskQueueDepth` | > 5 · 15 min | advertencia |
| `database-ebsiobalance-low` / `-ebsbytebalance-low` | crédito EBS | < 20 % · 15 min | advertencia |
| `database-cpu-credits-low` | `CPUCreditBalance` | < 30 · 15 min | advertencia |
| `database-saturated` (compuesta) | correlación | ver abajo | crítico |

### Umbrales derivados, no escritos a mano

Conexiones y disco se calculan desde `database_max_connections` y
`database_allocated_storage`. Cambiar la clase de instancia o ampliar el volumen
mueve las alarmas con ellos; escribir `42` a mano las deja mintiendo en silencio
el día que alguien toque la instancia.

**`database_max_connections`: dev 120 (provisional), prod 60.** El parameter
group deja `max_connections` en su fórmula de sistema
`{DBInstanceClassMemory/12582880}`, así que **el motor lo recalcula solo al
cambiar de clase**: la variable no configura nada, solo declara de qué número
cuelgan los umbrales. La aritmética pura da 85 para 1 GiB y 170 para 2 GiB, pero
lo medido en `db.t4g.micro` fueron 60 — RDS reserva memoria y el efectivo sale en
torno a 0,70 del aritmético. Por eso dev declara 120 al subir a `db.t4g.small`:
es la extrapolación de ese factor, y se declara por lo bajo a propósito, porque
quedarse corto adelanta las alarmas (ruido corregible) mientras que pasarse las
deja mudas y el cliente recibe *Too many connections* sin aviso previo.

`DBInstanceClassMemory` no lo expone ningún `describe-*`. **Al cambiar
`database_instance_class` hay que reconfirmarlo contra la instancia ya
arrancada** y ajustar la variable al valor medido:

```sql
SHOW GLOBAL VARIABLES LIKE 'max_connections';
```

Prod corre `db.t4g.small` pero sigue declarando el default del módulo, 60. Sus
alarmas de conexiones avisan antes de tiempo, que es el lado seguro del error;
alinearlo es un cambio aparte, con su propia medición.

### La alarma que pidió el negocio

`database-saturated` es la respuesta a *«la base está con sobreconsumo y se puede
caer»*. Ninguna métrica sola contesta eso: CPU al 80 % no es un incidente. CPU al
80 % **con** el pool de conexiones lleno, o con la memoria libre en el piso, es
una base que se cae en los próximos minutos.

```
(CPU alta Y conexiones altas)  O
(CPU alta Y memoria baja)      O
(conexiones altas Y memoria baja) O
(memoria baja Y swap en uso)
```

Las cuatro hijas son advertencias y publican en el topic normal. La compuesta
escala al topic crítico. No hay mensajes duplicados: lo que aporta es la
correlación, no la repetición.

### Créditos de ráfaga

`EBSIOBalance%`, `EBSByteBalance%` y `CPUCreditBalance` solo se publican en la
familia `t`. Agotarlos no produce ningún error: el throughput cae a la línea
base y la base «de repente está lenta» sin que ninguna métrica clásica lo
explique. Las dos de EBS usan `notBreaching` para que mover el entorno a otra
clase no deje alarmas colgadas.

`CPUCreditBalance` es la excepción: usa `ignore`. Parar una instancia de clase
`t` **borra el saldo acumulado** —al encender arranca en 0—, y como el ambiente
se apaga cada noche el saldo rara vez llega al umbral antes del siguiente
apagado. Con `notBreaching`, el apagado producía un datapoint faltante y la
alarma anunciaba OK en Slack como si se hubiera recuperado, estando el saldo
real cerca de cero. `ignore` conserva el último estado conocido mientras no hay
datos, así que deja de fingir recuperación; y como no hay cambio de estado,
tampoco genera notificaciones extra. A cambio, si el entorno pasa a una clase
que no publica la métrica estando en ALARM, esa alarma queda colgada.

## 4. Cache Valkey

Las sesiones y el rate limiting viven ahí: un cache que rechaza comandos tumba la
API igual que una base caída. Los límites de dev son deliberadamente bajos —1 GB
y 1.000 ECPU/s— para fijar el costo, lo que hace que tocarlos sea plausible.

| Alarma | Umbral | Severidad |
| --- | --- | --- |
| `cache-storage-high` | > 80 % de 1 GB | advertencia |
| `cache-ecpu-high` | > 80 % de 1.000 ECPU/s | advertencia |
| `cache-throttled` | ≥ 1 comando rechazado | crítico |
| `cache-auth-failures` | ≥ 1 fallo de autenticación | crítico |

`ElastiCacheProcessingUnits` se acumula **por periodo** mientras que el límite se
expresa **por segundo**: el umbral es `1000 × 300 × 0,8 = 240.000`.

Serverless usa la dimensión `clusterId`. `CacheClusterId` es la de los clusters
por nodos y dejaría la alarma sin datos para siempre.

`cache-auth-failures` cubre un fallo real y documentado: un apply cortado a la
mitad deja al usuario de ElastiCache y al secreto de conexión con valores
distintos del password efímero, y el backend arranca y muere con
`WRONGPASS invalid username-password pair`. La salida es subir
`valkey_password_version`.

## 5. Eventos que ninguna métrica anuncia

Hay fallas que llegan como evento, no como serie temporal. Para cuando
`FreeStorageSpace` muestre el desplome, la base ya lleva minutos abajo.

| Regla | Qué captura | Severidad |
| --- | --- | --- |
| `ecs-task-failed` | `EssentialContainerExited`, `TaskFailedToStart` | crítico |
| `ecs-deployment-failed` | `SERVICE_DEPLOYMENT_FAILED` (circuit breaker) | crítico |
| `ecs-service-impaired` | `SERVICE_TASK_PLACEMENT_FAILURE`, `SERVICE_TASK_START_IMPAIRED`, `SERVICE_TASK_CONFIGURATION_FAILURE`, `ECS_OPERATION_THROTTLED` | crítico |
| `database-critical-events` | RDS-EVENT-0403 (memoria críticamente baja), 0007/0221/0222/0330 (disco), 0031/0035/0036 (estado incompatible), 0022 (fallo al reiniciar), 0418/0419 (KMS inaccesible) | crítico |
| `database-warning-events` | RDS-EVENT-0089 (disco < 10 %), 0013/0015/0049 (failover), 0223/0224 (autoescalado), 0026 (parches offline), 0155 (upgrade menor) | advertencia |

La lista de EventIDs es explícita a propósito. Suscribirse a la categoría
`availability` completa traería también RDS-EVENT-0004 y 0006 —apagado y
reinicio—, que en dev son el apagado programado de cada noche.

### El incidente que ya está ocurriendo

`RDS-EVENT-0403` —«*a database workload is causing the system to run critically
low on memory; RDS automatically set innodb_buffer_pool_size to …*»— **no es
hipotético en este entorno**. RDS lo emitió el 5, 6 y 7 de agosto de 2026,
siempre cerca de las **12:34 UTC**, bajando el buffer pool a 27 MB, con la
instancia encadenando shutdown, recovery y restart hasta quedar `stopped`.

Es el evento más valioso de la lista por dos razones: llega **antes** de que el
motor se caiga, y **dice la causa**. El apagado y el reinicio que vienen después
(RDS-EVENT-0004 y 0006) son indistinguibles del apagado programado de cada
noche, así que no sirven como señal.

Las alarmas que también lo cubren, en orden de aparición:

1. `database-low-memory` (< 256 MiB) — el primer aviso, todavía con margen.
2. `database-swap-usage` (dev < 64 MiB) — confirma presión real de memoria.
3. `database-saturated` — la pareja memoria baja + swap escala a crítico.
4. `database-memory-exhausted` (< 96 MiB) — el motor está por reiniciarse.
5. `RDS-EVENT-0403` — RDS ya intervino por su cuenta.

### Por qué los umbrales de memoria no se duplicaron con la RAM

Al pasar dev de 1 GiB a 2 GiB la tentación es escalar los umbrales en proporción
—256 → 512 MiB y 96 → 192 MiB—. Sería un error. `FreeableMemory` mide **margen
absoluto hasta el swap**, y ese margen no crece porque haya más RAM instalada:
MySQL dimensiona `innodb_buffer_pool_size` como una fracción de
`DBInstanceClassMemory`, así que el motor se expande hasta ocupar la memoria
nueva y la memoria libre en reposo **no se duplica**. Un umbral de advertencia en
512 MiB quedaría en el entorno del estado normal de la instancia y sonaría de
forma permanente: exactamente el ruido que ya arrastra la alarma de créditos de
CPU. Los dos umbrales se quedan por tanto en 256 MiB y 96 MiB, y el de 96 MiB
tiene además respaldo empírico — el mínimo observado durante la crisis fue
71,9 MB, es decir, la alarma sí disparó antes del reinicio.

`SwapUsage` es el caso contrario y sí se recalibra. Con 1 GiB el swap sostenido
era crónico —380,9 MB de media, pico de 540,1 MB— y un umbral de 128 MiB llegaba
tarde: cuando se cruzaba, la instancia ya estaba en el crash loop. Con 2 GiB el
swap sostenido debería desaparecer, de modo que cualquier swap significativo
vuelve a ser una señal temprana. Dev baja a **64 MiB**, por encima de los pocos MB
de páginas ociosas que Linux mueve en reposo y muy por debajo del territorio
donde el motor ya está perdido, conservando la ventana de 15 minutos sostenidos
para que un pico aislado no despierte a nadie. Prod conserva 128 MiB.

`database-cpu-credits-low` se queda en 30 créditos. `db.t4g.small` tiene los
mismos 2 vCPU que `micro`, así que 30 créditos son el mismo tiempo absoluto de
ráfaga; lo que cambia es que la línea base a la que cae al agotarlos es el doble
(20 % frente a 10 %), o sea que la condición es **menos** grave que antes, no más.
Escalarla en proporción la haría disparar antes por un problema menor.

**Arreglo de fondo, ya en código y pendiente de aplicar:** la instancia era
insuficiente para la carga. `environments/dev` declara `db.t4g.small` (2 GiB) en
lugar de `db.t4g.micro`; el `apply` va por su workflow con aprobación humana.
Identificar el trabajo diario de las ~12:34 UTC sigue pendiente y es
independiente del tamaño: las alertas hacen visible el problema, no lo resuelven.

`innodb_buffer_pool_size` **no está fijado** en el parameter group (queda en
`engine-default`), así que las bajadas a 27 MB fueron ajustes dinámicos en
caliente de RDS y no una escritura persistente: al arrancar con 2 GiB el motor
recalcula el buffer pool desde cero y no arrastra ese lastre.

**Precondición operativa del cambio de clase:** la instancia de dev pasa la mayor
parte del tiempo `stopped` por el apagado programado. Un `modify` sobre una
instancia parada puede rechazarse o quedarse en cola hasta el autoarranque de los
siete días. **Hay que arrancar dev con `Start dev environment` antes de aplicar**
y confirmar que la instancia está `available`.

Después del primer arranque en `small`, dos verificaciones obligatorias:
reconfirmar `database_max_connections` con `SHOW GLOBAL VARIABLES` y observar
`FreeableMemory` durante una o dos semanas para validar que 256 MiB y 96 MiB
siguen siendo umbrales útiles con el nuevo tamaño de buffer pool.

`SERVICE_TASK_PLACEMENT_FAILURE` con `reason: RESOURCE:FARGATE` es la falla más
probable de dev: el servicio corre 100 % en Fargate Spot y significa que AWS no
tiene capacidad Spot que entregar. No se arregla con código, se arregla dándole
peso temporal a Fargate on-demand.

### Formato en Slack

Cada regla transforma el evento al esquema de notificaciones personalizadas de
Amazon Q Developer (`version: "1.0"`, `source: "custom"`,
`content.description`) mediante un *input transformer* de EventBridge. Slack
recibe un mensaje redactado con causa y pasos siguientes en vez de un volcado
JSON, y no hace falta un Lambda intermedio.

## 6. El apagado programado no despierta a nadie

Dev apaga ECS a las 20:00 y RDS a las 20:15 de lunes a viernes. RDS deja de
publicar métricas cuando está detenida.

**Ninguna alarma usa `treat_missing_data = "breaching"`.** La alarma de memoria
de RDS lo hacía y disparaba una alerta diaria a las 20:15, que es la forma más
rápida de enseñarle a un equipo a ignorar el canal. Hay un test que lo impide
volver a introducir: `scheduled_shutdown_does_not_page`.

## 6.bis El envío de logs a Grafana Cloud

Estas tres viven en `modules/log_shipping`, no en `modules/monitoring`, porque
vigilan un tramo con dueño propio. Se cablean a los mismos dos topics de
severidad del entorno.

Existen porque el fallo de este camino no es ruidoso: la aplicación sigue
respondiendo, CloudWatch sigue teniendo todos los eventos y lo único que ocurre
es que Loki deja de recibirlos. Así se abrió el hueco de 50 minutos que originó
el cambio.

| Alarma | Métrica | Umbral | Qué significa |
| --- | --- | --- | --- |
| `logs-delivery-failing` | `DeliveryToHttpEndpoint.Success` | < 1 durante 10 min | crítico · el endpoint rechaza. Clave de acceso sin el `1706326:` delante, token sin `logs:write`, 429, endpoint del stack equivocado o petición por encima de 5 MiB |
| `logs-in-error-bucket` | `DeliveryToS3.Records` | ≥ 1 en 5 min | crítico · Firehose agotó los reintentos y depositó registros en `s3://vetsoftware-dev-logs-backup-.../errors/`. Eso **no** está en Loki |
| `logs-delivery-stalled` | `DeliveryToHttpEndpoint.DataFreshness` | > 15 min | advertencia · sigue reintentando. Loki va con retraso, todavía no hay pérdida |

`DeliveryToS3.Records` se usa como medida de "hay objetos bajo el prefijo de
error" a propósito: con `s3_backup_mode = "FailedDataOnly"` lo único que Firehose
escribe en ese bucket son los registros que no pudo entregar, y las métricas de
S3 por prefijo son métricas de petición y se facturan. Esta es gratuita y llega
antes.

Las tres usan `treat_missing_data = "notBreaching"` por la misma razón que el
resto: dev se apaga cada noche y sin tráfico Firehose no publica métrica.

## 6.ter El sidecar de trazas y métricas

Los logs se protegieron fuera de la tarea (6.bis). Las trazas y las métricas se
protegen **dentro**, con un sidecar `opentelemetry-collector-contrib` que encola
en disco y reintenta media hora. El sidecar no procesa logs y no hace
`tail_sampling`: el muestreo lo decide Adaptive Traces en Grafana Cloud, que ve
la traza completa, y un colector por tarea solo vería su trozo.

El contenedor es `essential = false` a propósito —si el colector cae, la API
sigue en pie— y esa decisión tiene un precio exacto: ECS **no** reemplaza la
tarea, **no** emite una parada y nadie se entera. Sin lo que sigue, esa bandera
sería una forma silenciosa de perder telemetría.

### Lo que sí se ve desde CloudWatch

| Alarma | Métrica | Umbral | Qué significa |
| --- | --- | --- | --- |
| `telemetry-sidecar-stopped` | `TelemetrySidecarStopped` | ≥ 1 en 5 min | crítico · el colector se detuvo con la tarea todavía corriendo. Trazas y métricas se quedaron sin cola durable y ECS no lo va a revivir: hay que forzar un despliegue |
| `telemetry-sidecar-errors` | `TelemetrySidecarErrors` | ≥ 5 en 5 min, dos ventanas | advertencia · sigue vivo y reintentando, pero la cola en disco está creciendo. Credenciales, endpoint o un path que `readonlyRootFilesystem` no le deja escribir |

`TelemetrySidecarStopped` sale de una regla de EventBridge distinta de la de la
sección 2. Aquella archiva paradas de **tarea** (`lastStatus = STOPPED`) y por
definición nunca verá morir a un contenedor no esencial, porque en ese caso la
tarea sigue `RUNNING`. Ésta archiva justo lo contrario —tarea viva, contenido
cambiando por dentro— en
`/aws/events/vetsoftware-dev/telemetry-container-state`, y el filtro recorre
todas las posiciones del array `containers` porque ECS no garantiza su orden. Un
contenedor `STOPPED` dentro de una tarea `RUNNING` solo puede ser el sidecar: el
backend y `cloudflared` son `essential` y su muerte se lleva la tarea entera.

`TelemetrySidecarErrors` lee el log group del propio colector. Por eso la
plantilla fuerza `service.telemetry.logs.encoding: json`: con el encoder de
consola por defecto no habría campo `$.level` que consultar y el filtro no
encontraría nada nunca.

Las dos usan `treat_missing_data = "notBreaching"`, como el resto del entorno:
dev se apaga cada noche.

### Lo que necesariamente vive en Grafana Cloud

Hay un tercer modo de fallo —**vivo, sin errores y sin entregar**— que CloudWatch
no puede ver. Las series que lo demuestran son métricas internas del colector y
viajan a Grafana Cloud por el mismo pipeline durable que todo lo demás, así que
sobreviven al corte que están denunciando: cuando Grafana vuelve, llega la serie
que explica el hueco. Esa propiedad es la razón de que las self-metrics salgan
por el propio receptor OTLP y no por un `/metrics` de Prometheus.

Las reglas ya estaban escritas para el stack de contenedores en
`VetSoftware/docker/prometheus-platform-alerts.yml:241-286`. Se reutilizan tal
cual, quitando solo las de logs, que aquí no aplican porque el sidecar no los
procesa:

```yaml
# Fallo sostenido de exportación. Con retry_on_failure un fallo aislado ya NO es
# pérdida: es un reintento. Por eso es warning y exige 10 minutos.
- alert: VetSoftwareOtelTraceExportFailing
  expr: increase(otelcol_exporter_send_failed_spans[5m]) > 0
  for: 10m
  labels: { severity: warning, domain: observability, service: vetsoftware }

# Pérdida consumada: la cola estaba llena y el dato se descartó.
- alert: VetSoftwareOtelQueueDroppingTelemetry
  expr: sum(increase(otelcol_exporter_enqueue_failed_spans[5m])) > 0
  for: 1m
  labels: { severity: critical, domain: observability, service: vetsoftware }

# Indicador adelantado: avisa antes de que la cola se llene y empiece a descartar.
- alert: VetSoftwareOtelQueueNearCapacity
  expr: |
    (
      otelcol_exporter_queue_size
      / clamp_min(otelcol_exporter_queue_capacity, 1)
    ) > 0.8
  for: 5m
  labels: { severity: warning, domain: observability, service: vetsoftware }
```

Una cuarta, que no existe en el fichero original y aquí sí hace falta, porque es
el contrapeso de `essential = false` visto desde el otro lado: silencio total del
colector. Debe acotarse a la ventana en la que dev está encendido, o el apagado
de las 20:00 la convierte en una página diaria.

```yaml
- alert: VetSoftwareOtelSidecarSilent
  expr: absent_over_time(otelcol_process_uptime{deployment_environment_name="dev"}[15m])
  for: 5m
  labels: { severity: warning, domain: observability, service: vetsoftware }
```

**Estas cuatro reglas no las crea Terraform.** Viven en el stack de Grafana Cloud
y hoy quedan documentadas, no aplicadas: cargarlas es un paso manual pendiente.

### Por qué el interruptor se entrega apagado

`telemetry_sidecar_enabled` está en `false`, y no por prudencia genérica.
`RemoteConnectionValidator` (`VetSoftware`, `@Profile({"dev","prod"})`,
`BeanFactoryPostProcessor` con `HIGHEST_PRECEDENCE`) rechaza `localhost`,
`127.0.0.1`, `0.0.0.0` y `::1` en `management.otlp.metrics.export.url` y en
`management.opentelemetry.tracing.export.otlp.endpoint`, que son exactamente las
dos propiedades que alimentan `OTEL_EXPORTER_OTLP_{METRICS,TRACES}_ENDPOINT`.
Dev arranca con `SPRING_PROFILES_ACTIVE=prod`, así que la validación aplica.

Encender el interruptor contra la imagen actual del backend no degrada la
telemetría: **impide arrancar la aplicación**, y lo hace antes de crear el
`DataSource`. Un sidecar es por definición un destino local, así que esa
validación tiene que aprender a permitir loopback para las dos rutas OTLP —y solo
para ellas— antes de que esto se pueda poner en `true`. Ese cambio vive en el
repositorio de la aplicación.

`OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` no se mueve en ninguna de las dos ramas.
Apuntarlo al sidecar daría 404 en `/v1/logs`, porque no existe ese pipeline, y su
durabilidad ya está resuelta por el camino de 6.bis. Y `OTEL_EXPORTER_OTLP_HEADERS`
sigue viniendo de `backend_secrets` siempre: la exportación OTLP de logs la
necesita para autenticarse, y el propio `RemoteConnectionValidator` se niega a
arrancar si está vacía.

## 7. Runbook

| Llega esto | Primero mirar | Salida habitual |
| --- | --- | --- |
| `backend-memory-exhausted` | `MemoryUtilization` de la última hora y GC en Grafana | fuga o carga real; subir `backend_memory` a 3072 es la mitigación inmediata |
| `backend-crash-loop` | `stoppedReason` en `/aws/events/vetsoftware-dev/ecs-task-state` | si menciona health check, comparar arranque real contra `startPeriod` (180 s) antes de tocar código |
| `ecs-service-impaired` con `RESOURCE:FARGATE` | nada que revisar | AWS sin capacidad Spot; darle peso a `fargate_weight` hasta que se recupere |
| `cloudflare-tunnel-errors` | `/ecs/vetsoftware-dev-backend/cloudflare-tunnel` | el túnel es el único camino público: la API está caída aunque la tarea esté sana |
| `database-connections-exhausted` | `SHOW PROCESSLIST` y el pool de Hikari | casi siempre conexiones sin devolver al pool, no carga |
| `database-storage-exhausted` | `FreeStorageSpace` | el autoescalado está apagado a propósito en dev: ampliar `database_allocated_storage` es manual |
| `database-saturated` | las cuatro hijas para ver cuál par se activó | dice qué recurso se agotó primero |
| `cache-auth-failures` tras un despliegue | `valkey_password_version` | subirla fuerza a reescribir usuario y secreto en el mismo apply |
| RDS-EVENT-0031 | consola de RDS | RDS recomienda restaurar a un punto en el tiempo; **no reiniciar a ciegas**, se pierde el diagnóstico |
| `logs-delivery-failing` | `/aws/kinesisfirehose/vetsoftware-dev-logs`, flujo `HttpEndpointDelivery` | ahí está la respuesta literal del endpoint. Un 401 casi siempre es la clave de acceso pegada sin el `1706326:` delante, o un token sin `logs:write`; un 502, una petición por encima de 5 MiB |
| `logs-in-error-bucket` | prefijo `errors/` del bucket de respaldo | los objetos son los eventos que faltan en Loki; el original sigue 14 días en `/ecs/vetsoftware-dev-backend/backend` |
| `logs-delivery-stalled` | `DeliveryToHttpEndpoint.Success` de la misma ventana | si Success sigue en 1, es lentitud del endpoint y se resuelve solo dentro de las dos horas de reintento |

## 8. Verificación

```powershell
# Contratos del módulo (8 runs) y del entorno
cd modules/monitoring ; terraform test
cd environments/dev   ; terraform test

# Gate completo antes de integrar
./scripts/quality/terraform-gate.ps1 -Mode full
```

Prueba de humo de extremo a extremo, sin esperar un incidente real:

```powershell
# 1. Publicar directo en el topic crítico y confirmar que Slack lo formatea
aws sns publish --topic-arn <critical-topic-arn> --message (Get-Content prueba.json -Raw)

# 2. Forzar una parada inesperada y verificar el conteo
aws ecs stop-task --cluster vetsoftware-dev-backend --task <task-id> --reason "prueba de alerta"
```

`stop-task` genera `stopCode: UserInitiated`, así que **no** cuenta como parada
inesperada: sirve para verificar el archivo en el log group, no la alarma de
crash loop. Para probar el conteo hay que provocar una salida real del
contenedor.

## 9. Lo que queda fuera

- **Producción sigue sin canal de notificación.** El módulo ya soporta todo lo
  anterior, pero `environments/prod/main.tf` no pasa `alarm_email`, ni Slack, ni
  las banderas de eventos, así que prod crea las alarmas de métrica sin destino
  al que notificar. Es el hallazgo INF-37 de la auditoría y queda fuera del
  alcance de este cambio, que era el backend de dev. Habilitarlo es pasar los
  mismos inputs que dev.
- **`RunningTaskCount` requiere Container Insights**, que en dev está apagado por
  costo. La alarma `backend-no-running-tasks` existe detrás de
  `container_insights_enabled` y se crea sola al encenderlo.
- **Sin SLO ni error budget.** No hay latencia ni tasa de error por endpoint
  publicadas como métrica; todo lo anterior alerta sobre síntomas de
  infraestructura, no sobre experiencia de usuario.
- **Sin canario sintético.** Nada verifica desde fuera que
  `https://<api_domain_name>` responde. CloudWatch Synthetics cada 5 minutos
  costaría del orden de USD 10/mes contra un presupuesto de 35.
