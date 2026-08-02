# Presupuesto y controles de costo

Los valores son una referencia inicial para `us-east-1`; AWS factura por uso, región, transferencia y volumen real. Revise el plan en AWS Pricing Calculator antes de producción.

| Recurso | Configuración inicial | Referencia mensual |
|---|---|---:|
| Backend Fargate | ARM64, 1 vCPU, 4 GiB, una tarea | USD 34 |
| EC2 Alloy | `t4g.micro` | USD 6.15 |
| EBS | 8 GiB, `gp3` | USD 0.64 |
| Application Load Balancer + IPv4 | Dos o más AZ | USD 25–32 |
| IPv4 públicas | Fargate y una EC2 | USD 7.30 |
| RDS MySQL | `db.t4g.small`, 20 GiB | USD 26–30 |
| Valkey Serverless | Carga baja | USD 6–10 |
| S3, Firehose, Route 53 y transferencia | Según uso | USD 6–20 |
| Cloudflare Pages | Plan Free | USD 0 |
| Grafana Cloud | Plan Free dentro de cuotas | USD 0 |
| **Total orientativo** |  | **USD 112–145** |

## Perfil de desarrollo

`environments/dev` elimina costos fijos duplicados y reduce los recursos variables:

| Recurso | Configuración dev |
|---|---|
| Red / ALB | Reutiliza VPC, dos AZ y ALB de `prod` mediante host routing |
| Backend | 512 CPU, 2048 MiB, solo Fargate Spot, escalado limitado a 0–1 tarea |
| RDS | `db.t4g.micro`, 20 GiB fijos, backup 1 día, sin deletion protection ni snapshot final |
| Valkey | Serverless limitado a 1 GB y 1000 ECPU/s |
| Telemetría | Exportación OTLP directa a Grafana Cloud; sin EC2 Alloy dedicada |
| Logs | Retención de 3 días; sin access logs de un ALB adicional |
| Horario | RDS 07:30–20:15 y ECS 08:00–20:00, lunes a viernes, `America/Bogota` |

ECS y RDS se controlan con EventBridge Scheduler mediante un rol de mínimo privilegio. RDS arranca antes que ECS y se detiene después para evitar tareas iniciando contra una base todavía apagada. El state de dev usa una key S3 independiente y no puede sobrescribir producción.

## Protecciones incluidas

- AWS Budget mensual configurable, con avisos al 80 % y 100 % cuando se define `alarm_email`.
- Auto Scaling de Fargate limitado por `backend_min_count` y `backend_max_count`.
- Valkey limitado por `valkey_maximum_data_storage_gb` y `valkey_maximum_ecpu_per_second`.
- RDS limitado por `database_max_allocated_storage`.
- Container Insights y monitoreo detallado de EC2 están desactivados por defecto para controlar costo.
- No se crea NAT Gateway; se usa un endpoint gateway S3 sin costo por hora.
- Logs y versiones no actuales de S3 tienen retenciones explícitas.

## Variables que más cambian la factura

1. `backend_desired_count`, `backend_cpu` y `backend_memory`.
2. `database_instance_class`, `database_multi_az` y almacenamiento.
3. Tráfico y retención en S3, Firehose, CloudWatch y Grafana Cloud.
4. Capacidad real consumida por Valkey Serverless.
5. Capacidad y cantidad de EC2 de Alloy.

El presupuesto no bloquea recursos ni detiene servicios: genera alertas. Para un control preventivo adicional se recomienda complementar con AWS Cost Anomaly Detection y políticas organizacionales.
