# Arquitectura de producción

## Flujo principal

```text
Cloudflare Pages (frontend)
        |
        | HTTPS API
        v
Application Load Balancer (2+ AZ)
        |
        v
ECS Fargate / Spring Boot (auto scaling)
   |          |            |             |
   |          |            |             +--> Grafana Alloy EC2 --> Grafana Cloud
   |          |            +----------------> Gotenberg EC2
   |          +-----------------------------> Valkey Serverless (TLS/RBAC)
   +----------------------------------------> RDS MySQL (TLS/private)
   |
   +--> S3 aplicación
   +--> Data Firehose --> S3 auditoría WORM
```

## Decisiones importantes

### Red sin NAT Gateway

El ALB, Fargate, Gotenberg y Alloy están en subredes públicas. Solo el ALB acepta tráfico de Internet; los grupos de seguridad de las otras cargas no tienen reglas públicas de entrada. Las tareas necesitan IP pública para descargar la imagen y llamar servicios externos, pero siguen siendo inaccesibles directamente.

Esta decisión ahorra el costo fijo y de procesamiento de NAT Gateway. Si una política futura exige cargas sin IP pública, se deben agregar NAT Gateway por AZ o VPC endpoints para ECR, S3, CloudWatch Logs, Secrets Manager, SSM y las demás APIs necesarias.

### Datos aislados

RDS y Valkey viven en subredes privadas sin ruta a Internet. Solo el security group del backend puede conectarse a sus puertos. RDS exige transporte TLS y Valkey usa TLS más RBAC.

### Secretos fuera del estado

Los valores ingresan como variables efímeras de Terraform 1.15 y se escriben mediante atributos write-only del proveedor AWS. El estado solo conserva los ARN y los contadores de versión. RDS genera y conserva su contraseña maestra directamente en Secrets Manager.

### Escalamiento

- ECS escala por CPU y memoria entre `backend_min_count` y `backend_max_count`.
- La primera tarea usa Fargate On-Demand; las adicionales pueden usar Spot.
- RDS autoescala almacenamiento hasta `database_max_allocated_storage` y puede habilitarse Multi-AZ.
- Valkey escala automáticamente, con topes configurables de almacenamiento y ECPU que evitan crecimiento de costo sin control.
- Gotenberg admite varias EC2 por DNS privado multi-A; cada instancia limita su cola y recursos.
- Alloy se mantiene en una instancia para conservar un gateway sencillo. Para alta disponibilidad se recomienda migrarlo a ECS con balanceo OTLP consciente de trazas.

## Límites operativos conocidos

- EC2 Gotenberg y Alloy usan servicios systemd con reinicio automático y alarmas de recuperación automática ante fallos del host. No usan Auto Scaling Group; para reemplazo automático ante fallos del sistema operativo se puede evolucionar el módulo a ASG.
- Cloudflare Pages y Grafana Cloud se configuran fuera de este repositorio; Terraform aprovisiona la integración AWS necesaria.
- Object Lock en modo COMPLIANCE impide borrar o reducir la retención de objetos de auditoría, incluso por administradores.
