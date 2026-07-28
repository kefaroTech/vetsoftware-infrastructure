# VetSoftwareIaC

Infraestructura como código para desplegar VetSoftware en AWS con Terraform.

## Arquitectura

- Backend Spring Boot en Amazon ECS con Fargate ARM64, detrás de un Application Load Balancer.
- Generación PDF embebida en el backend con OpenHTMLToPDF.
- Grafana Alloy en una EC2 Graviton pequeña como gateway OTLP hacia Grafana Cloud.
- Amazon RDS for MySQL privado, cifrado y con almacenamiento autoescalable.
- Amazon ElastiCache Serverless for Valkey privado, TLS y RBAC.
- Bucket S3 de aplicación y bucket de auditoría WORM con Object Lock.
- Amazon Data Firehose para entregar el outbox de auditoría al bucket WORM.
- Secrets Manager con argumentos write-only y valores efímeros: los secretos no se guardan en el plan ni en el estado.
- Estado remoto S3 cifrado, versionado y con locking nativo de S3.
- Auto Scaling del backend, alarmas de CloudWatch y presupuesto mensual opcional.

La configuración económica evita NAT Gateway por defecto. Fargate y la EC2 de Alloy reciben salida a Internet, pero sus security groups solo permiten entradas explícitas. RDS y Valkey permanecen en subredes privadas.

## Versiones fijadas

- Terraform `1.15.8`.
- AWS Provider `6.56.x`.
- Random Provider `3.9.x`.
- Grafana Alloy `1.18.0`.

Las restricciones admiten parches compatibles, pero evitan actualizaciones mayores accidentales.

## Requisitos

- Terraform 1.15.x.
- TFLint 0.64.x para ejecutar la revisión local completa.
- AWS CLI v2 autenticado con permisos administrativos para el bootstrap y el despliegue.
- Una imagen ARM64 publicada del backend. También puede usarse x86 cambiando `backend_cpu_architecture`.
- Un dominio en Route 53 o un certificado ACM existente si se habilita HTTPS.
- Credenciales OTLP de Grafana Cloud.

## 1. Crear el backend remoto

```powershell
$env:TF_VAR_project_name = "vetsoftware"
$env:TF_VAR_environment  = "prod"
$env:TF_VAR_aws_region   = "us-east-1"

terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
```

La forma recomendada crea el bucket, genera `backend.hcl` e inicializa producción automáticamente:

```powershell
./scripts/bootstrap.ps1
```

Para automatización controlada puede usar `./scripts/bootstrap.ps1 -AutoApprove`. `backend.hcl.example` también permite una configuración manual.

El backend usa locking nativo de S3 (`use_lockfile = true`); DynamoDB no se utiliza porque ese mecanismo está deprecado.

## 2. Definir variables de entorno

Terraform lee automáticamente las variables prefijadas con `TF_VAR_`.

```powershell
$env:AWS_REGION = "us-east-1"
$env:TF_VAR_project_name = "vetsoftware"
$env:TF_VAR_environment = "prod"
$env:TF_VAR_backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware:1.0.0"

$env:TF_VAR_api_domain_name = "api.vetsoftware.co"
$env:TF_VAR_route53_zone_id = "Z0123456789ABCDEFG"
$env:TF_VAR_create_certificate = "true"

$env:TF_VAR_cors_allowed_origins = '["https://app.vetsoftware.co","https://admin.vetsoftware.co"]'
$env:TF_VAR_email_from = "VetSoftware <notificaciones@vetsoftware.co>"
$env:TF_VAR_registration_verification_url = "https://app.vetsoftware.co/verify-email"
$env:TF_VAR_password_reset_url = "https://app.vetsoftware.co/restablecer-contrasena"
$env:TF_VAR_login_url = "https://app.vetsoftware.co/login"

$env:TF_VAR_application_secrets_json = '{"JWT_SECRET":"BASE64_256_BITS","RESEND_API_KEY":"re_xxx","RECAPTCHA_SECRET":"xxx"}'
$env:TF_VAR_grafana_secrets_json = '{"OTLP_USERNAME":"123456","OTLP_API_KEY":"glc_xxx"}'
$env:TF_VAR_grafana_otlp_endpoint = "https://otlp-gateway-prod-us-east-0.grafana.net/otlp"
```

Los dos JSON son variables `ephemeral` y llegan a Secrets Manager mediante `secret_string_wo`; no quedan almacenados por Terraform. Para rotarlos, cambie el valor y aumente `application_secret_version` o `grafana_secret_version`.

## 3. Planificar y aplicar

```powershell
./scripts/validate.ps1
./scripts/plan.ps1
./scripts/apply.ps1
```

O directamente:

```powershell
terraform -chdir=environments/prod plan -out=vetsoftware.tfplan
terraform -chdir=environments/prod apply vetsoftware.tfplan
```

## Parametrización de capacidad

Ejemplos:

```powershell
# RDS más pequeña
$env:TF_VAR_database_instance_class = "db.t4g.micro"

# Más capacidad de base de datos
$env:TF_VAR_database_instance_class = "db.t4g.medium"
$env:TF_VAR_database_allocated_storage = "40"
$env:TF_VAR_database_max_allocated_storage = "200"
$env:TF_VAR_database_multi_az = "true"

# Backend Fargate
$env:TF_VAR_backend_cpu = "1024"
$env:TF_VAR_backend_memory = "4096"
$env:TF_VAR_backend_desired_count = "1"
$env:TF_VAR_backend_max_count = "4"

# Protección de memoria del render PDF embebido
$env:TF_VAR_pdf_max_concurrent_renders = "2"
$env:TF_VAR_pdf_max_pdf_size = "25MB"

# Gateway de telemetría
$env:TF_VAR_alloy_instance_type = "t4g.micro"
```

Consulte `environments/prod/terraform.tfvars.example` para todas las opciones principales.
El presupuesto detallado y sus controles están en `docs/COSTS.md`.

## Seguridad y operación

- No se crean llaves SSH; el acceso operativo se realiza con AWS Systems Manager Session Manager.
- IMDSv2 es obligatorio en EC2.
- Todos los discos y bases de datos están cifrados.
- El bucket de auditoría tiene Object Lock en modo COMPLIANCE y `prevent_destroy`.
- El rol de la tarea ECS solo puede publicar en su Firehose y operar sobre el bucket de aplicación.
- Las credenciales de Grafana solo son legibles por la EC2 de Alloy.
- Alloy solo acepta tráfico OTLP del security group del backend.
- La eliminación accidental de ALB, RDS y buckets se controla mediante variables o protecciones explícitas.

## Destrucción

El bucket WORM tiene `prevent_destroy` y los objetos bloqueados no pueden eliminarse antes de vencer su retención. Esto es intencional. Para retirar el resto:

```powershell
terraform -chdir=environments/prod destroy
```

El bucket de auditoría debe conservarse o gestionarse mediante un procedimiento de retiro separado y auditado.
