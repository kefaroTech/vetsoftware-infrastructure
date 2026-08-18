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
| Backend | 512 CPU, 2048 MiB, solo Fargate Spot, escalado limitado a 0-1 tarea |
| RDS | `db.t4g.small`, 20 GiB fijos, backup 7 dias, proteccion contra borrado y snapshot final |
| Valkey | Serverless limitado a 1 GB y 1000 ECPU/s |
| Telemetria | Exportacion OTLP directa a Grafana Cloud; sin EC2 Alloy dedicada |
| Logs | Retención de 3 días para backend y `cloudflared` |
| KMS | CMK de datos dev + CMK exclusiva del state dev, desde USD 2 al mes mas solicitudes |
| Horario | Encendido manual con `Start dev environment`; apagado programado ECS 20:00 y RDS 20:15, lunes a viernes, `America/Bogota` |

Tener VPC propia no agrega costo fijo: la VPC, las subredes, el Internet Gateway y el S3 Gateway Endpoint no se facturan. El aislamiento agrega una CMK de state por ambiente y la ingesta de VPC Flow Logs de una segunda red, acotada por la retencion de tres dias de dev.

Dev subio de `db.t4g.micro` (1 GiB) a `db.t4g.small` (2 GiB) porque la alarma de memoria se repitio: seis `RDS-EVENT-0403` con el InnoDB buffer pool reducido a 27 MiB, `FreeableMemory` minimo de 71,9 MB y `SwapUsage` medio de 380,9 MB. Era el escalon previsto en este mismo documento y se ejecuta sin tocar el resto del perfil: 20 GiB gp3 fijos, Single-AZ, backup de siete dias, IAM DB Auth, proteccion contra borrado y snapshot final.

El precio horario confirmado en catalogo pasa de USD 0,016 a USD 0,032. Con el apagado programado de las 20:15 de lunes a viernes, el costo mensual de dev pasa de **USD 20,59 a USD 24,46**, un delta de **+USD 3,87** sobre un presupuesto de USD 35. El suelo fijo del entorno, USD 13,75, no se mueve: solo se encarecen las horas encendidas. La linea de RDS de la tabla de prod ya presupuestaba `db.t4g.small` y sigue vigente.

Los umbrales de memoria de las alarmas **no se escalan con la RAM**: `FreeableMemory` mide margen absoluto hasta el swap y MySQL expande su buffer pool hasta ocupar la memoria nueva, asi que 256 MiB y 96 MiB siguen siendo las marcas correctas. Lo que si se endurece en dev es el umbral de swap, de 128 a 64 MiB. El detalle esta en `docs/ALERTAS_OPERATIVAS.md`.

Dos condiciones antes de aplicar: la instancia de dev suele estar `stopped` por el apagado programado y un `modify` sobre una instancia parada puede rechazarse o quedar en cola, asi que hay que arrancarla con `Start dev environment` primero; y `database_max_connections` queda declarado provisionalmente en 120 hasta medirlo con `SHOW GLOBAL VARIABLES` contra la instancia ya arrancada en `small`. El siguiente escalon, si la memoria vuelve a agotarse, seria `db.t4g.medium`; no se reduce la proteccion de backups.

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
