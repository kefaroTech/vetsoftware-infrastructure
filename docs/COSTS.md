# Presupuesto y controles de costo

Los valores son una referencia inicial para `us-east-1`; AWS factura por uso, region, transferencia y volumen real. Revise el plan en AWS Pricing Calculator antes de produccion.

| Recurso | Configuracion inicial | Referencia mensual |
|---|---|---:|
| Backend Fargate | ARM64, 1 vCPU, 4 GiB, una tarea | USD 34 |
| EC2 Alloy | `t4g.micro` | USD 6.15 |
| EBS | 8 GiB, `gp3` | USD 0.64 |
| IPv4 publicas | Fargate y una EC2 | USD 7.30 |
| RDS MySQL | `db.t4g.small`, 20 GiB | USD 26-30 |
| Valkey Serverless | Carga baja | USD 6-15 |
| S3 Gateway Endpoint | Tablas publicas y de datos | USD 0 adicional |
| KMS | CMK de datos prod + CMK exclusiva del state prod | Desde USD 2 mas solicitudes |
| VPC Flow Logs y logs ECS/Cloudflare | Ingesta y retención según tráfico | USD 5-20 iniciales |
| S3, Firehose y transferencia | Segun uso | USD 6-20 |
| Cloudflare Tunnel | Plan Free | USD 0 |
| Cloudflare Pages | Plan Free | USD 0 |
| Grafana Cloud | Plan Free dentro de cuotas | USD 0 |
| **Total orientativo prod aislado** |  | **USD 91-147** |

Los ocho Interface Endpoints en dos AZ y el ALB fueron eliminados por decisión FinOps. El ahorro base combinado es aproximadamente USD 139,06 mensuales más procesamiento de datos y logs de acceso. Fargate y Alloy conservan IPv4 pública; el backend no acepta conexiones de entrada y `cloudflared` usa `localhost`.

## Perfil de desarrollo

`environments/dev` es independiente de produccion y sostiene su costo con capacidad minima, no compartiendo recursos:

| Recurso | Configuracion dev |
|---|---|
| Red | VPC propia `10.50.0.0/16` con dos AZ y S3 Gateway Endpoint; sin ALB, sin NAT Gateway y sin Interface Endpoints |
| Backend | 512 CPU, 3072 MiB de tarea, solo Fargate Spot, escalado limitado a 0-1 tarea |
| RDS | `db.t4g.small`, 20 GiB fijos, backup 7 dias, proteccion contra borrado y snapshot final |
| Valkey | Serverless limitado a 1 GB y 1000 ECPU/s |
| Telemetria | Trazas y metricas por sidecar colector con cola en disco (interruptor `telemetry_sidecar_enabled`, hoy apagado); sin EC2 Alloy dedicada |
| Logs | Retención de 3 días, salvo el log group del backend, en 14 |
| Envío de logs | CloudWatch → Kinesis Firehose → Grafana Cloud, con respaldo en S3 |
| KMS | CMK de datos dev + CMK exclusiva del state dev, desde USD 2 al mes mas solicitudes |
| Horario | Encendido manual con `Start dev environment`; apagado programado ECS 20:00 y RDS 20:15, lunes a viernes, `America/Bogota` |

Tener VPC propia no agrega costo fijo: la VPC, las subredes, el Internet Gateway y el S3 Gateway Endpoint no se facturan. El aislamiento agrega una CMK de state por ambiente y la ingesta de VPC Flow Logs de una segunda red, acotada por la retencion de tres dias de dev.

Dev subio de `db.t4g.micro` (1 GiB) a `db.t4g.small` (2 GiB) porque la alarma de memoria se repitio: seis `RDS-EVENT-0403` con el InnoDB buffer pool reducido a 27 MiB, `FreeableMemory` minimo de 71,9 MB y `SwapUsage` medio de 380,9 MB. Era el escalon previsto en este mismo documento y se ejecuta sin tocar el resto del perfil: 20 GiB gp3 fijos, Single-AZ, backup de siete dias, IAM DB Auth, proteccion contra borrado y snapshot final.

El precio horario confirmado en catalogo pasa de USD 0,016 a USD 0,032. Con el apagado programado de las 20:15 de lunes a viernes, el costo mensual de dev pasa de **USD 20,59 a USD 24,46**, un delta de **+USD 3,87** sobre un presupuesto de USD 35. El suelo fijo del entorno, USD 13,75, no se mueve: solo se encarecen las horas encendidas. La linea de RDS de la tabla de prod ya presupuestaba `db.t4g.small` y sigue vigente.

Los umbrales de memoria de las alarmas **no se escalan con la RAM**: `FreeableMemory` mide margen absoluto hasta el swap y MySQL expande su buffer pool hasta ocupar la memoria nueva, asi que 256 MiB y 96 MiB siguen siendo las marcas correctas. Lo que si se endurece en dev es el umbral de swap, de 128 a 64 MiB. El detalle esta en `docs/ALERTAS_OPERATIVAS.md`.

Dos condiciones antes de aplicar: la instancia de dev suele estar `stopped` por el apagado programado y un `modify` sobre una instancia parada puede rechazarse o quedar en cola, asi que hay que arrancarla con `Start dev environment` primero; y `database_max_connections` queda declarado provisionalmente en 120 hasta medirlo con `SHOW GLOBAL VARIABLES` contra la instancia ya arrancada en `small`. El siguiente escalon, si la memoria vuelve a agotarse, seria `db.t4g.medium`; no se reduce la proteccion de backups.

### Envío durable de logs a Grafana Cloud

Dev dejó de depender de la cola en memoria del exportador OTLP para que sus logs
lleguen a Loki. La frontera de durabilidad pasa a ser CloudWatch Logs —que ya los
tenía todos— y el último tramo lo hace Kinesis Firehose, que reintenta dos horas
y deposita en S3 lo que no logre entregar. El motivo fue un hueco de 50 minutos
en Loki, con la aplicación viva y los 310 eventos correctos en CloudWatch.

| Línea | Cálculo | Referencia mensual |
|---|---|---:|
| **Secreto dedicado en Secrets Manager** | USD 0,40 por secreto | **USD 0,40** |
| Firehose, destino HTTP | USD 0,029/GB sobre ~1,5 GB/mes | USD 0,05 |
| S3 de respaldo | Solo lo no entregado; vacío en operación normal | < USD 0,01 |
| Log group operativo de Firehose | Unas pocas líneas por entrega fallida | < USD 0,01 |
| Retención del backend, 3 → 14 días | ~0,55 GB-mes extra a USD 0,03/GB | < USD 0,02 |
| **Delta total** | | **≈ USD 0,48** |

**La línea cara no es Firehose: es el secreto.** Secrets Manager cobra USD 0,40
por secreto y mes, ocho veces el tramo de entrega. Se paga a propósito. La
alternativa —añadir la clave al secreto `grafana-cloud` que ya existe— sale
gratis pero apuesta a que Firehose tolere claves hermanas en el JSON, algo que
AWS no documenta: solo dice que fallará al conectar si el formato no es el
correcto, y ese fallo es silencioso y en tiempo de entrega, exactamente la clase
de fallo que este trabajo existe para eliminar. Cuarenta céntimos es un precio
barato por no volver a depender de que nadie mire.

Tres precisiones sobre el resto. Firehose factura por incrementos de 5 KB por
registro, así que el GB facturable es algo mayor que el GB enviado; con este
caudal la diferencia sigue siendo de céntimos. La suscripción del log group no
tiene cargo propio: la ingesta a CloudWatch ya está pagada y lo que se añade es
el tramo de Firehose. Y el respaldo en S3 usa `FailedDataOnly`, así que en
operación normal el bucket está vacío y no cuesta nada: si empieza a costar, es
que la alarma `vetsoftware-dev-logs-in-error-bucket` ya sonó.

El buffer de entrega va en 1 MB y 60 segundos, que son los valores de las
plantillas oficiales de Grafana Labs. El tamaño no es una palanca de ahorro:
**el endpoint rechaza con HTTP 502 cualquier petición por encima de 5 MiB**, así
que el máximo admitido por la variable es 5 y subirlo más no abarata nada, solo
convierte las entregas en rechazos que únicamente se ven en el log group de
Firehose.

La retención del backend se subió con una variable propia,
`backend_log_retention_days`, y no tocando `log_retention_days`: esa la comparten
los flow logs, RDS, `account_baseline` y el informe de costos, y subirla para
todos habría multiplicado un gasto que aquí solo hace falta en un log group.

### Sidecar colector de trazas y métricas

Los logs ya no dependían de una cola en memoria; las trazas y las métricas sí.
Salían por OTLP directo desde la aplicación y, cuando Grafana Cloud tardaba en
responder, el `BatchSpanProcessor` descartaba en silencio. La durabilidad de esas
dos señales se resuelve **dentro** de la tarea, con un sidecar
`opentelemetry-collector-contrib` que encola en disco y reintenta media hora.
Es a propósito el camino contrario al de los logs, que se resuelve fuera de la
tarea con CloudWatch y Firehose: cada señal por donde le sale más barato y más
fiable.

El sidecar no procesa logs y no hace `tail_sampling`. El muestreo lo decide
Adaptive Traces en el lado de Grafana Cloud, que ve la traza entera; un colector
por tarea solo vería su trozo.

| Línea | Cálculo | Referencia mensual |
|---|---|---:|
| Memoria de tarea, 2048 → 3072 MiB | +1 GiB a USD 0,001334/GB-h (Fargate Spot ARM64) sobre ~210 h encendidas | USD 0,28 |
| Log group del sidecar | Retención de 3 días, unas decenas de líneas por arranque | < USD 0,01 |
| Volumen de la cola | Almacenamiento efímero de tarea, dentro de los 20 GiB incluidos | USD 0 |
| Trazas al 100 % en Grafana Cloud | ~0,9 spans/s ≈ 2,3 GB/mes contra 50 GB del plan Free | USD 0 |
| **Delta con el interruptor apagado** | | **+USD 0,28** |

Ese es el delta que aplica hoy, porque `telemetry_sidecar_enabled` se entrega en
`false` (el motivo está en `docs/ALERTAS_OPERATIVAS.md`, sección 6.ter: la
validación de arranque de la aplicación todavía rechaza `localhost`). La memoria
sube igual y no se desperdicia: sin sidecar, el backend recibe 2944 MiB en vez de
los 1920 MiB de hoy, que es más margen para la JVM del que tiene ahora.

Al encender el interruptor se suman las líneas de observabilidad, que conviene
tener contadas antes y no descubrirlas en la factura:

| Línea al encender | Cálculo | Referencia mensual |
|---|---|---:|
| Métricas personalizadas | `TelemetrySidecarStopped` y `TelemetrySidecarErrors`, USD 0,30 cada una | USD 0,60 |
| Alarmas CloudWatch | Dos alarmas de resolución estándar, USD 0,10 cada una | USD 0,20 |
| Log group de eventos de contenedor | Retención del entorno, unos pocos eventos al día | < USD 0,01 |
| **Delta acumulado con el sidecar activo** | | **+USD 1,08** |

Dos precisiones. La primera: subir el muestreo de 0,25 a 1,0 **no** cuadruplica
ningún coste de AWS, porque los spans no pasan por CloudWatch; multiplica por
cuatro el volumen enviado a Grafana Cloud, y ahí el margen es de tres órdenes de
magnitud sobre el límite de ingesta (~0,9 spans/s medidos contra ~1.250
soportados). La segunda: el sidecar reserva 64 CPU y 256 MiB dentro de la tarea,
así que **no** añade coste de cómputo por sí mismo; lo único que se factura es
que la tarea creció para no quitarle memoria al backend.

Si en algún momento se prefiere no pagar los USD 0,28 hasta que el sidecar se
pueda encender de verdad, basta con dejar `backend_memory = 2048` en las
variables del entorno: el resto del cambio es inerte con el interruptor apagado.

## Protecciones incluidas

- AWS Budget mensual configurable, con avisos al 80 % y 100 % cuando se define `alarm_email`.
- Informe diario en Slack del gasto del dia anterior por servicio, y de la semana pasada los lunes. Es la unica proteccion que cuesta: Cost Explorer cobra USD 0.01 por request y el informe hace una consulta al dia, ~USD 0.30 al mes.
- Deteccion de anomalias de costo con aviso inmediato a Slack sobre el umbral `cost_anomaly_threshold_usd`. Necesita diez dias de historia antes de detectar y tarda hasta 24 horas en avisar.
- Auto Scaling de Fargate limitado por `backend_min_count` y `backend_max_count`.
- Valkey limitado por `valkey_maximum_data_storage_gb` y `valkey_maximum_ecpu_per_second`.
- RDS limitado por `database_max_allocated_storage` y protegido contra borrado.
- Container Insights y monitoreo detallado de EC2 estan desactivados por defecto para controlar costo.
- No se crea NAT Gateway ni Interface Endpoints; S3 usa un endpoint Gateway y las demas APIs AWS usan salida HTTPS publica.
- Logs y versiones no actuales de S3 tienen retenciones explicitas.
- No se factura ALB ni LCU; Cloudflare Tunnel conecta directamente con el backend local de cada tarea.

El presupuesto no bloquea recursos ni detiene servicios: genera alertas. CloudWatch, VPC Flow Logs, KMS, IPv4 y transferencia deben incluirse en cualquier estimacion futura.
