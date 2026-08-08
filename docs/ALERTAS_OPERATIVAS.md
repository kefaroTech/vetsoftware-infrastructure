# Alertas operativas del entorno dev

Contrato de alertas de `vetsoftware-dev`: qué se vigila, con qué umbral, por qué
ese umbral y qué hacer cuando llega el mensaje a Slack.

Todo vive en `modules/monitoring` y se cablea desde `environments/dev/main.tf`.
El inventario en vivo se consulta con `terraform output alerting`.

---

## 1. Ruteo por tipo de señal

Cuatro topics, tres canales. La separación es por **tipo de señal**, no por
severidad: una alarma dice que algo está mal, un evento dice que algo pasó, y un
aviso de costo no exige nada hoy. Cada familia tiene su ritmo, y mezclarlas hace
que la más frecuente entierre a la más importante.

| Topic | Contenido | Canal |
| --- | --- | --- |
| `vetsoftware-dev-alarms` | alarmas de advertencia | alertas |
| `vetsoftware-dev-alarms-critical` | alarmas críticas y compuestas | alertas |
| `vetsoftware-dev-events` | despliegues, apagados, eventos de ECS y RDS | infra |
| `vetsoftware-dev-finops` | informe diario, presupuesto, anomalías | costos |

La severidad sigue partida en dos topics aunque ambos vayan al mismo canal. No
cuesta nada y deja mandar lo crítico a una guardia más adelante con
`slack_critical_channel_id`, sin volver a repartir nada.

### Variables de canal

| Variable | Familia | Si está vacía |
| --- | --- | --- |
| `slack_channel_id` | costos, y todo lo que no tenga canal propio | deshabilita Slack |
| `slack_alerts_channel_id` | alarmas | cae al canal base |
| `slack_infra_channel_id` | eventos | cae al canal base |
| `slack_critical_channel_id` | alarmas críticas | acompañan a las advertencias |

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
| `-finops` | `budgets.amazonaws.com`, `costalerts.amazonaws.com`, el rol `iac-plan-dev` |

Los tres scripts derivan el ARN por convención y hay que moverlos si cambian los
nombres: `cost-report.ps1` usa `-finops`, `dev-environment.ps1` usa `-events`, y
`backend-image.ps1` lee `events_topic_arn` del output `alerting`.

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
| `database-connections-high` | `DatabaseConnections` | > 42 (70 % de 60) | advertencia |
| `database-connections-exhausted` | `DatabaseConnections` | > 54 (90 % de 60) | crítico |
| `database-low-storage` | `FreeStorageSpace` | < 5 GiB (25 %) | advertencia |
| `database-storage-exhausted` | `FreeStorageSpace` | < 2 GiB (10 %) | crítico |
| `database-low-memory` | `FreeableMemory` | < 256 MiB | advertencia |
| `database-memory-exhausted` | `FreeableMemory` mínimo | < 96 MiB · 3 de 5 × 1 min | crítico |
| `database-swap-usage` | `SwapUsage` | > 128 MiB · 15 min | advertencia |
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

**`database_max_connections = 60`.** RDS calcula `max_connections` como
`{DBInstanceClassMemory/12582880}`, y AWS documenta que en clases micro la
memoria reservada deja el resultado alrededor de 60. **Al cambiar
`database_instance_class` hay que reconfirmarlo:**

```sql
SHOW GLOBAL VARIABLES LIKE 'max_connections';
```

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
2. `database-swap-usage` — confirma presión real de memoria.
3. `database-saturated` — la pareja memoria baja + swap escala a crítico.
4. `database-memory-exhausted` (< 96 MiB) — el motor está por reiniciarse.
5. `RDS-EVENT-0403` — RDS ya intervino por su cuenta.

**Arreglo de fondo, no cubierto por ninguna alerta:** la instancia es
insuficiente para la carga. Subir a `db.t4g.small` (2 GiB) o identificar el
trabajo diario de las ~12:34 UTC. Las alertas hacen visible el problema, no lo
resuelven — y si se sube de clase, hay que reconfirmar
`database_max_connections`.

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
