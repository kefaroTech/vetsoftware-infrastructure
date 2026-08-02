# Arquitectura de produccion

## Flujo principal

```text
Cloudflare Pages (frontends)
        |
        | HTTPS
        v
Cloudflare Edge
        |
        | Tunnel saliente TCP/7844
        v
cloudflared sidecar (ECS) --> ALB HTTPS interno --> Spring Boot (ECS)
                                                    |      |      |
                                                    |      |      +--> Grafana Alloy --> Grafana Cloud
                                                    |      +---------> Valkey TLS/RBAC
                                                    +----------------> RDS MySQL TLS
                                                    |
                                                    +--> S3 aplicacion
                                                    +--> Firehose --> S3 auditoria WORM
```

## Entrada privada

El ALB tiene esquema `internal`, solo escucha HTTPS/443 y su security group acepta conexiones exclusivamente desde los conectores Cloudflare de las tareas ECS. No existe listener HTTP, IP publica de origen ni regla de entrada por CIDR.

Cada tarea incluye un sidecar `cloudflared` fijado por digest y autenticado con un token independiente por entorno. El transporte se fuerza a HTTP/2 y solo permite TCP/7844 hacia los rangos oficiales de Cloudflare. La configuracion de host publico y origen se completa en Cloudflare siguiendo [Cloudflare Tunnel](CLOUDFLARE_TUNNEL.md).

## Salida controlada sin NAT Gateway

La VPC crea endpoints Interface en dos AZ para ECR API/DKR, CloudWatch Logs, Secrets Manager, Firehose, SSM, SSM Messages y EC2 Messages. S3 usa un endpoint Gateway. Los security groups permiten HTTPS hacia el grupo de endpoints y no hacia toda Internet.

Resend, reCAPTCHA, Grafana Cloud y cualquier SaaS adicional deben declarar sus CIDR reales en `approved_external_https_ipv4_cidrs`. La ruta `0.0.0.0/0` esta prohibida por validacion y por el escaneo IaC. Esta postura aumenta el costo fijo de PrivateLink y exige mantenimiento operativo de los rangos externos.

## Datos y cifrado

RDS y Valkey viven en subredes de datos sin ruta a Internet. Solo el security group del backend puede conectarse a sus puertos. RDS exige TLS, conserva al menos siete dias de backups, tiene proteccion contra borrado, snapshot final e IAM DB Auth habilitado; la autenticacion por password administrado sigue disponible durante la migracion del cliente JDBC.

Una CMK con rotacion por entorno cifra S3 y los grupos de CloudWatch. El bucket de auditoria conserva Object Lock en modo COMPLIANCE. VPC Flow Logs registra todo el trafico con retencion explicita.

## Secretos fuera del estado

Los valores ingresan como variables efimeras de Terraform 1.15 y se escriben mediante atributos write-only del proveedor AWS. El estado solo conserva ARN y contadores de version. RDS genera y conserva su password maestro directamente en Secrets Manager.

## Escalamiento y desarrollo

- ECS escala por CPU y memoria entre `backend_min_count` y `backend_max_count`; cada replica abre conexiones independientes al mismo tunel del entorno.
- RDS autoescala almacenamiento hasta `database_max_allocated_storage` y puede habilitarse Multi-AZ.
- Valkey escala automaticamente dentro de sus topes de almacenamiento y ECPU.
- Desarrollo comparte VPC, endpoints privados y ALB con produccion, pero mantiene task, target group, RDS, Valkey, KMS, bucket y secretos separados.
- Desarrollo conserva `db.t4g.micro`, siete dias de backup y alarma de memoria libre a 256 MiB.

Cloudflare Pages, las rutas de Tunnel y Grafana Cloud se configuran fuera de AWS; Terraform aprovisiona y protege el origen y los conectores necesarios.
