# VetSoftwareIaC

Infraestructura como código para desplegar VetSoftware en AWS con Terraform.

## Arquitectura

- Backend Spring Boot en Amazon ECS con Fargate ARM64 y sin balanceador de carga.
- Cloudflare Tunnel como sidecar por tarea, conectado a `http://localhost:8080`; no existe entrada pública directa al origen AWS.
- Generación PDF embebida en el backend con OpenHTMLToPDF.
- Grafana Alloy en una EC2 Graviton pequeña como gateway OTLP hacia Grafana Cloud.
- Amazon RDS for MySQL privado, cifrado y con almacenamiento autoescalable.
- Amazon ElastiCache Serverless for Valkey privado, TLS y RBAC.
- Bucket S3 de aplicación y bucket de auditoría WORM con Object Lock.
- Amazon Data Firehose para entregar el outbox de auditoría al bucket WORM.
- Secrets Manager con argumentos write-only y valores efímeros: los secretos no se guardan en el plan ni en el estado.
- Estado remoto S3 cifrado, versionado y con locking nativo de S3.
- Auto Scaling del backend, alarmas de CloudWatch y presupuesto mensual opcional.
- CMK con rotación por entorno, VPC Flow Logs y logs JSON de backend y `cloudflared` en CloudWatch.
- Salida HTTPS pública explícita para APIs AWS y dependencias SaaS, sin entrada pública al backend.

La configuración evita NAT Gateway e Interface Endpoints de pago. S3 conserva su endpoint Gateway gratuito; ECR, Logs, Secrets Manager, Firehose y SSM se consumen por HTTPS mediante las IPv4 públicas de Fargate y Alloy. RDS y Valkey permanecen en subredes privadas.

## Entornos

- `environments/prod`: infraestructura completa y protegida, con VPC, Alloy, RDS, Valkey y archivo de auditoría propios.
- `environments/dev`: state y datos separados, pero reutiliza por tags la VPC y sus subredes. Ejecuta como máximo una tarea ARM64 de 512 CPU/2048 MiB exclusivamente en Fargate Spot, RDS `db.t4g.micro`, Valkey 1 GB/1000 ECPU y logs de tres días. Exporta OTLP directamente a Grafana Cloud, sin otra EC2 Alloy.

Compartir solo la red reduce costo sin compartir base de datos, cache, secretos, KMS, bucket ni roles. Cada entorno usa un túnel y token independientes; sus hostnames remotos apuntan a `http://localhost:8080` dentro de la tarea correspondiente.

## Versiones fijadas

- Terraform `1.15.8`.
- AWS Provider `6.56.x`.
- Random Provider `3.9.x`.
- Grafana Alloy `1.18.0`.

Las restricciones admiten parches compatibles, pero evitan actualizaciones mayores accidentales.

## Requisitos

- Terraform 1.15.x.
- TFLint 0.64.0 para ejecutar la revisión local completa.
- PowerShell, Git Bash y Docker con el daemon activo para el gate pre-commit completo.
- AWS CLI v2 autenticado con permisos administrativos para el bootstrap y el despliegue.
- Una imagen ARM64 publicada del backend. También puede usarse x86 cambiando `backend_cpu_architecture`.
- La zona `kefaro.tech` activa en Cloudflare y dos túneles remotos independientes para `api.kefaro.tech` y `dev-api.kefaro.tech`.
- Credenciales OTLP de Grafana Cloud.

## Gate pre-commit de Terraform

`core.hooksPath` apunta a `.githooks` y el pre-commit ejecuta un gate fail-closed: higiene del snapshot, Gitleaks, versiones exactas, formato, TFLint desde severidad `notice`, `validate` sin advertencias, contratos `terraform test` y Trivy IaC desde severidad `MEDIUM`.

```powershell
# Calidad Terraform sin exigir que el arbol este preparado
./scripts/validate.ps1

# Gate identico al pre-commit
./scripts/quality/terraform-gate.ps1 -Mode full
```

El progreso se imprime en vivo y los logs persistentes quedan en `.tools/logs/terraform-gate/`. IntelliJ importa tres configuraciones compartidas desde `.run/`; las instrucciones para agregarlas a Services y la política de cero tolerancia están en [Gate de calidad Terraform](docs/TERRAFORM_QUALITY_GATE.md).

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
$env:TF_VAR_backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

$env:TF_VAR_api_domain_name = "api.kefaro.tech"

$env:TF_VAR_cors_allowed_origins = '["https://app.vetsoftware.co","https://admin.vetsoftware.co"]'
$env:TF_VAR_email_from = "VetSoftware <notificaciones@vetsoftware.co>"
$env:TF_VAR_registration_verification_url = "https://app.vetsoftware.co/verify-email"
$env:TF_VAR_password_reset_url = "https://app.vetsoftware.co/restablecer-contrasena"
$env:TF_VAR_login_url = "https://app.vetsoftware.co/login"

$env:TF_VAR_application_secrets_json = '{"JWT_SECRET":"BASE64_256_BITS","RESEND_API_KEY":"re_xxx","RECAPTCHA_SECRET":"xxx"}'
$env:TF_VAR_grafana_secrets_json = '{"OTLP_USERNAME":"123456","OTLP_API_KEY":"glc_xxx"}'
$env:TF_VAR_cloudflare_tunnel_token = "TOKEN_TUNEL_PROD"
$env:TF_VAR_grafana_otlp_endpoint = "https://otlp-gateway-prod-us-east-0.grafana.net/otlp"
```

Los dos JSON y el token Cloudflare son variables `ephemeral` y llegan a Secrets Manager mediante `secret_string_wo`; no quedan almacenados por Terraform. Para rotarlos, cambie el valor y aumente el contador de versión correspondiente.

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

## Desplegar desarrollo

Producción debe existir primero porque dev descubre su VPC y subredes mediante tags. Los states usan el mismo bucket protegido, pero keys independientes: `vetsoftware/prod/terraform.tfstate` y `vetsoftware/dev/terraform.tfstate`.

```powershell
Copy-Item environments/dev/backend.hcl.example environments/dev/backend.hcl
Copy-Item environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars
./scripts/init.ps1 -Environment dev
./scripts/plan.ps1 -Environment dev -Output vetsoftware-dev.tfplan
./scripts/apply.ps1 -Environment dev -Plan vetsoftware-dev.tfplan
```

El bootstrap genera ambos `backend.hcl` automáticamente. Dev se enciende de lunes a viernes: RDS a las 07:30, ECS a las 08:00, ECS se apaga a las 20:00 y RDS a las 20:15, en `America/Bogota`. Los horarios se controlan con `*_schedule`, `schedule_timezone` y `scheduled_shutdown_enabled`.

La autenticación OTLP directa se almacena como `OTEL_EXPORTER_OTLP_HEADERS` dentro del JSON efímero de Grafana. Consulte [el ejemplo de variables](environments/dev/terraform.tfvars.example) para construir el encabezado Basic sin guardarlo en Git.

## Migrar una instalación que todavía tenga ALB

Antes de aplicar esta versión, cambie en Cloudflare los hostnames de dev y prod a `http://localhost:8080` y compruebe ambos health endpoints. Después aplique en este orden:

1. Deshabilitar explícitamente la deletion protection del ALB existente, si ya fue desplegado.
2. `environments/dev`, para retirar dependencias que pertenecen al state de desarrollo.
3. `environments/prod`, para destruir el ALB y sus recursos exclusivos.
4. `bootstrap`, para retirar al final los permisos OIDC temporales de ACM, ELB y log delivery.

No aplique `bootstrap` primero: los roles de los entornos necesitan sus permisos anteriores durante la eliminación controlada. El procedimiento y las comprobaciones están detallados en [Cloudflare Tunnel](docs/CLOUDFLARE_TUNNEL.md).

La creación de los túneles y las rutas públicas se documenta en [Cloudflare Tunnel](docs/CLOUDFLARE_TUNNEL.md).

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
- El security group del backend no tiene reglas de entrada: `cloudflared` alcanza Spring Boot por `localhost` dentro de la misma tarea.
- RDS conserva siete días de backup, tiene IAM DB Auth, protección contra borrado y snapshot final en ambos entornos.
- El quality gate no admite mecanismos que oculten hallazgos de seguridad.

## Destrucción

El bucket WORM tiene `prevent_destroy` y los objetos bloqueados no pueden eliminarse antes de vencer su retención. Esto es intencional. Para retirar el resto:

```powershell
terraform -chdir=environments/prod destroy
```

El bucket de auditoría debe conservarse o gestionarse mediante un procedimiento de retiro separado y auditado.

Dev no crea bucket WORM, pero su RDS sí tiene protección contra borrado. Para retirarlo debe aprobarse primero un cambio Terraform explícito que quite esa protección; después puede destruirse independientemente:

```powershell
terraform -chdir=environments/dev destroy
```

## Registro de imágenes y GitHub Actions

El bootstrap también crea tres repositorios ECR inmutables:

- `vetsoftware-backend`
- `vetsoftware-front`
- `vetsoftware-public-front`

Cada repositorio escanea al push, cifra con AES-256, elimina imágenes sin tag después de siete días y conserva las 30 imágenes más recientes por omisión. `prevent_destroy` evita borrar accidentalmente los repositorios.

El bootstrap crea un único proveedor OIDC de GitHub. El módulo ECR crea un rol IAM de mínimo privilegio por repositorio de aplicación, mientras que el módulo `github_iac_roles` crea roles independientes para plan y apply de Terraform. La confianza queda limitada por los nombres e IDs inmutables de la organización y el repositorio, además del GitHub Environment exacto; no se almacenan access keys en GitHub.

Para repositorios nuevos, obtenga los IDs inmutables antes de aplicar el bootstrap:

```powershell
gh api orgs/kefaroTech --jq .id
gh api repos/kefaroTech/VetSoftware --jq .id
gh api repos/kefaroTech/VetSoftwareFront --jq .id
gh api repos/kefaroTech/VetSoftwarePublicFront --jq .id
gh api repos/kefaroTech/VetSoftwareIaC --jq .id
```

Copie los resultados en `github_organization_id` y `github_repository_ids`. GitHub incorporó estos IDs al subject OIDC de repositorios creados después del 15 de julio de 2026, por lo que los valores deben coincidir exactamente.

Si la cuenta ya tiene el proveedor `token.actions.githubusercontent.com`, establezca `existing_github_oidc_provider_arn` en el bootstrap para reutilizarlo en lugar de intentar crear un duplicado.

Después de aplicar el bootstrap, obtenga los valores:

```powershell
terraform -chdir=bootstrap output ecr_repository_urls
terraform -chdir=bootstrap output github_ecr_publisher_role_arns
terraform -chdir=bootstrap output github_iac_role_arns
terraform -chdir=bootstrap output github_iac_environments
```

En cada repositorio GitHub abra **Settings > Environments > production > Environment variables** y configure:

| Repositorio GitHub | `AWS_ECR_PUBLISH_ROLE_ARN` | Variable adicional |
|---|---|---|
| `VetSoftware` | output `backend` | — |
| `VetSoftwareFront` | output `private_front` | — |
| `VetSoftwarePublicFront` | output `public_front` | `VITE_RECAPTCHA_SITE_KEY` |

`AWS_REGION` es opcional y usa `us-east-1` por omisión. Restrinja el environment `production` a la rama `main` y mantenga sus aprobadores obligatorios.

En la política de Actions de la organización deben estar permitidas y fijadas por SHA estas familias: `aws-actions/configure-aws-credentials`, `aws-actions/amazon-ecr-login`, `docker/setup-qemu-action`, `docker/setup-buildx-action` y `docker/build-push-action`.

### Roles OIDC de Terraform

La primera ejecución del bootstrap es deliberadamente administrativa: crea el proveedor OIDC, los repositorios ECR y los roles. Los cuatro roles resultantes administran exclusivamente los roots `environments/dev` y `environments/prod`; no pueden modificar el propio bootstrap. Los cambios futuros de identidad, state o ECR deben seguir ejecutándose mediante el procedimiento controlado de bootstrap.

En **VetSoftwareIaC > Settings > Environments** cree estos nombres exactos y agregue en cada uno la variable de environment `AWS_IAC_ROLE_ARN` con el ARN correspondiente del output `github_iac_role_arns`:

| GitHub Environment | Output | Capacidad |
|---|---|---|
| `iac-plan-dev` | `dev.plan` | Leer infraestructura y state de dev; administrar solo su lockfile. |
| `iac-apply-dev` | `dev.apply` | Aplicar dev y escribir exclusivamente el state de dev. |
| `iac-plan-prod` | `prod.plan` | Leer infraestructura y state de prod; administrar solo su lockfile. |
| `iac-apply-prod` | `prod.apply` | Aplicar prod y escribir exclusivamente el state de prod. |

Los roles `plan` no pueden mutar infraestructura ni escribir el state; solo crean y eliminan su lockfile para mantener el bloqueo nativo de S3. Plan y apply pueden certificar metadatos y hallazgos exclusivamente de `vetsoftware-backend`. Los roles `apply` limitan IAM, Secrets Manager y S3 por cuenta, entorno y prefijo; las mutaciones de servicios regionales se restringen a `aws_region`. Ningún rol permite `secretsmanager:GetSecretValue`, y cada trust policy exige audiencia `sts.amazonaws.com` y el subject inmutable del repositorio IaC.

Los buckets administrados deben conservar el patrón `vetsoftware-<entorno>-*`. Si una variable `application_bucket_name` o `audit_bucket_name` usa otro nombre, declare su ARN exacto en `additional_s3_bucket_arns` dentro de `github_iac_environments`; no amplíe la política a `arn:aws:s3:::*`.

Proteja como mínimo `iac-apply-prod` con revisor obligatorio, impida la autoaprobación, limite el despliegue a `main` y mantenga `Wait timer` desactivado salvo que exista una exigencia operativa. Para este workflow manual limite también `iac-apply-dev` a `main`; cualquier promoción automática desde `develop` requerirá una trust policy específica. El workflow image-only no recibe secretos de runtime: usa marcadores efímeros de validación y bloquea cualquier cambio fuera de ECS. Mantenga los roles de plan sin permisos AWS de mutación.

`deploy-backend.yml` consume estos roles para el circuito especializado de imágenes: certifica ECR, ejecuta un plan limitado a ECS, exige aprobación antes del apply, espera estabilidad, ejecuta smoke test y revierte al digest anterior cuando es posible. El plan general de PR y la detección periódica de drift siguen siendo tareas independientes.

Al cerrar con merge un PR `release/X.Y.Z` hacia `main`, cada workflow valida nuevamente calidad y versión, publica la imagen antes del tag y asigna dos tags ECR: `X.Y.Z` y `sha-<12 caracteres>`. Una reejecución solo continúa si ambos tags ya apuntan al mismo digest; un estado parcial o conflictivo bloquea la release. El backend solicita después un despliegue auditable por digest mediante una GitHub App de alcance exclusivo al repositorio IaC.

La configuración completa, el requisito de baseline y las variables externas pendientes están en [Despliegue inmutable del backend](docs/BACKEND_IMAGE_DEPLOYMENT.md).

Los fronts continúan desplegándose en Cloudflare Pages según la arquitectura actual. Sus imágenes ECR proporcionan un artefacto reproducible para ejecución local, recuperación o una migración futura; Terraform consume directamente la imagen ARM64 del backend mediante `backend_image_uri`.
