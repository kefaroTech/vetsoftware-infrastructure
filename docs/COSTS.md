# Presupuesto y controles de costo

Los valores son una referencia inicial para `us-east-1`; AWS factura por uso, región, transferencia y volumen real. Revise el plan en AWS Pricing Calculator antes de producción.

| Recurso | Configuración inicial | Referencia mensual |
|---|---|---:|
| Backend Fargate | ARM64, 1 vCPU, 4 GiB, una tarea | USD 34 |
| EC2 Gotenberg | `t4g.small` | USD 12.30 |
| EC2 Alloy | `t4g.micro` | USD 6.15 |
| EBS | 12 GiB + 8 GiB, `gp3` | USD 1.50–2 |
| Application Load Balancer + IPv4 | Dos o más AZ | USD 25–32 |
| IPv4 públicas | Fargate y dos EC2 | USD 10.95 |
| RDS MySQL | `db.t4g.small`, 20 GiB | USD 26–30 |
| Valkey Serverless | Carga baja | USD 6–10 |
| S3, Firehose, Route 53 y transferencia | Según uso | USD 6–20 |
| Cloudflare Pages | Plan Free | USD 0 |
| Grafana Cloud | Plan Free dentro de cuotas | USD 0 |
| **Total orientativo** |  | **USD 130–160** |

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
5. Cantidad de EC2 de Gotenberg y Alloy.

El presupuesto no bloquea recursos ni detiene servicios: genera alertas. Para un control preventivo adicional se recomienda complementar con AWS Cost Anomaly Detection y políticas organizacionales.
