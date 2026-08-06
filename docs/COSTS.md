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
| RDS | `db.t4g.micro`, 20 GiB fijos, backup 7 dias, proteccion contra borrado y snapshot final |
| Valkey | Serverless limitado a 1 GB y 1000 ECPU/s |
| Telemetria | Exportacion OTLP directa a Grafana Cloud; sin EC2 Alloy dedicada |
| Logs | Retención de 3 días para backend y `cloudflared` |
| KMS | CMK de datos dev + CMK exclusiva del state dev, desde USD 2 al mes mas solicitudes |
| Horario | Encendido manual con `Start dev environment`; apagado programado ECS 20:00 y RDS 20:15, lunes a viernes, `America/Bogota` |

Tener VPC propia no agrega costo fijo: la VPC, las subredes, el Internet Gateway y el S3 Gateway Endpoint no se facturan. El aislamiento agrega una CMK de state por ambiente y la ingesta de VPC Flow Logs de una segunda red, acotada por la retencion de tres dias de dev.

Mantener `db.t4g.micro` es una decision explicita de costo. IAM DB Auth queda habilitado y una alarma se activa si la memoria libre media cae por debajo de 256 MiB durante diez minutos. Si esa alarma se repite, el siguiente ajuste debe ser `db.t4g.small`; no se reduce la proteccion de backups.

## Protecciones incluidas

- AWS Budget mensual configurable, con avisos al 80 % y 100 % cuando se define `alarm_email`.
- Auto Scaling de Fargate limitado por `backend_min_count` y `backend_max_count`.
- Valkey limitado por `valkey_maximum_data_storage_gb` y `valkey_maximum_ecpu_per_second`.
- RDS limitado por `database_max_allocated_storage` y protegido contra borrado.
- Container Insights y monitoreo detallado de EC2 estan desactivados por defecto para controlar costo.
- No se crea NAT Gateway ni Interface Endpoints; S3 usa un endpoint Gateway y las demas APIs AWS usan salida HTTPS publica.
- Logs y versiones no actuales de S3 tienen retenciones explicitas.
- No se factura ALB ni LCU; Cloudflare Tunnel conecta directamente con el backend local de cada tarea.

El presupuesto no bloquea recursos ni detiene servicios: genera alertas. CloudWatch, VPC Flow Logs, KMS, IPv4 y transferencia deben incluirse en cualquier estimacion futura.
