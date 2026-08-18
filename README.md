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

- `environments/prod`: infraestructura completa y protegida, con VPC `10.40.0.0/16`, Alloy, RDS, Valkey y archivo de auditoría propios.
- `environments/dev`: infraestructura completa e independiente, con VPC propia `10.50.0.0/16`. Ejecuta como máximo una tarea ARM64 de 512 CPU/2048 MiB exclusivamente en Fargate Spot, RDS `db.t4g.small`, Valkey 1 GB/1000 ECPU y logs de tres días. Exporta OTLP directamente a Grafana Cloud, sin otra EC2 Alloy.

**Los dos entornos son independientes y no comparten recursos administrados.** Cada uno tiene bootstrap, bucket de state, KMS, ECR backend, roles, VPC, datos, secretos y workflows propios. Pueden desplegarse en cualquier orden o existir por separado. El único prerrequisito externo de la cuenta es el proveedor OIDC de GitHub.

Los CIDR no deben solaparse. Si cambia `vpc_cidr` en un entorno, verifique que el otro conserve un rango distinto.

## Versiones fijadas

- Terraform `1.15.8`.
- AWS Provider `6.56.x`.
- Random Provider `3.9.x`.
- Grafana Alloy `1.18.0`.

Las restricciones admiten parches compatibles, pero evitan actualizaciones mayores accidentales.

## Requisitos

- Repositorio publicado en GitHub con `develop` y `main` protegidas.
- Proveedor OIDC de GitHub creado una sola vez en la cuenta AWS.
- Roles iniciales y GitHub Environments separados para bootstrap dev y prod.
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

## Despliegue desde GitHub Actions

No ejecute Terraform localmente. La primera ejecución y las siguientes ocurren en Actions:

1. `Terraform bootstrap dev` desde `develop` o `Terraform bootstrap prod` desde `main`.
2. Publicación de la imagen inmutable del mismo ambiente.
3. `Terraform plan dev/prod`.
4. Revisión del plan.
5. `Terraform apply dev/prod` manual y protegido.

Dev usa `vetsoftware-dev-tfstate-<cuenta>` y `vetsoftware-dev-backend`. Prod usa `vetsoftware-prod-tfstate-<cuenta>` y `vetsoftware-backend`; ninguno necesita que el bootstrap del otro exista. Consulte [Bootstrap sin ejecución local](docs/BOOTSTRAP_AUTOMATION.md) y [Automatización Terraform](docs/TERRAFORM_AUTOMATION.md).

El backend usa locking nativo de S3 (`use_lockfile = true`); DynamoDB no se utiliza.

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

El bucket WORM tiene `prevent_destroy` y los objetos bloqueados no pueden eliminarse antes de vencer su retención. Esto es intencional. El retiro del resto se prepara mediante PR y se ejecuta con `Terraform apply prod`; no se usa `terraform destroy` local.

El bucket de auditoría debe conservarse o gestionarse mediante un procedimiento de retiro separado y auditado.

Dev no crea bucket WORM, pero su RDS sí tiene protección contra borrado. Para retirarlo debe aprobarse primero un cambio Terraform explícito que quite esa protección y aplicarlo desde `Terraform apply dev`.

## Registro de imágenes y GitHub Actions

Los bootstraps crean repositorios ECR inmutables sin propiedad cruzada:

- `vetsoftware-dev-backend`, propiedad exclusiva de dev.
- `vetsoftware-backend`
- `vetsoftware-front`
- `vetsoftware-public-front`

Los tres nombres sin `-dev-` pertenecen exclusivamente a prod. Cada repositorio escanea al push, cifra con AES-256 y tiene `prevent_destroy`.

Los artefactos de desarrollo y producción no conviven en un mismo repositorio:

| Origen | Rama | Environment GitHub | Prefijo del tag | Retención |
|---|---|---|---|---|
| Release productiva | `main` | `production` | `X.Y.Z` y `sha-<12>` | 30 imágenes |
| Imagen de desarrollo | `develop` | `development` | `dev-<12>` en `vetsoftware-dev-backend` | 10 imágenes |

Los fronts siguen siendo `production-only`: su entorno dev vive en Cloudflare Pages y no necesita imagen.

El proveedor OIDC de GitHub se crea una sola vez fuera de Terraform. Cada bootstrap recibe su ARN pero no adquiere propiedad sobre él. El módulo ECR crea publicadores solo para su ambiente y `github_iac_roles` crea únicamente el par plan/apply correspondiente.

Para repositorios nuevos, obtenga los IDs inmutables antes de aplicar el bootstrap:

```powershell
gh api orgs/kefaroTech --jq .id
gh api repos/kefaroTech/vetsoftware-backend --jq .id
gh api repos/kefaroTech/VetSoftwareFront --jq .id
gh api repos/kefaroTech/VetSoftwarePublicFront --jq .id
gh api repos/kefaroTech/vetsoftware-infrastructure --jq .id
```

Configure el ID del propietario como `GH_ORGANIZATION_ID` y los IDs de repositorio dentro de `GH_REPOSITORY_IDS_JSON` en el GitHub Environment de bootstrap. GitHub incorporó estos IDs al subject OIDC de repositorios creados después del 15 de julio de 2026, por lo que los valores deben coincidir exactamente.

Los outputs se publican en los logs del workflow de bootstrap correspondiente; no se consultan mediante Terraform local.

En cada repositorio GitHub abra **Settings > Environments > production > Environment variables** y configure:

| Repositorio GitHub | `AWS_ECR_PUBLISH_ROLE_ARN` | Variable adicional |
|---|---|---|
| `vetsoftware-backend` | output `backend` | — |
| `VetSoftwareFront` | output `private_front` | — |
| `VetSoftwarePublicFront` | output `public_front` | `VITE_RECAPTCHA_SITE_KEY` |

En ese mismo environment seleccione **Deployment branches and tags > Selected branches and tags**, agregue únicamente la rama protegida `main`, configure al menos un required reviewer e impida la autoaprobación. Esta regla externa es obligatoria: el subject OIDC demuestra el environment `production`, mientras que la política de deployment de GitHub impide que un workflow modificado en una rama dev llegue a ese environment.

Además, en `vetsoftware-backend` cree **Settings > Environments > development** y configure `AWS_ECR_PUBLISH_ROLE_ARN` con el output `github_ecr_development_publisher_role_arns.backend`. Limite sus deployment branches a `develop` y no le agregue required reviewers: el ciclo de dev debe avanzar sin bloquearse en producción. Es un rol distinto, con una trust policy distinta, así que ninguna credencial se comparte entre los dos ciclos.

`AWS_REGION` es opcional y usa `us-east-1` por omisión.

En la política de Actions de la organización deben estar permitidas y fijadas por SHA estas familias: `aws-actions/configure-aws-credentials`, `aws-actions/amazon-ecr-login`, `docker/setup-qemu-action`, `docker/setup-buildx-action` y `docker/build-push-action`.

### Roles OIDC de Terraform

La primera ejecución de cada bootstrap es deliberadamente administrativa: crea su backend remoto, su ECR y su par de roles plan/apply. Dev no crea roles de prod y prod no crea roles de dev. Los cambios futuros de identidad, state o ECR se ejecutan nuevamente desde el workflow protegido del mismo ambiente.

En **vetsoftware-infrastructure > Settings > Environments** cree estos nombres exactos y agregue en cada uno la variable `AWS_ACCOUNT_ID`. El ARN del rol no se configura: cada workflow lo arma como `arn:aws:iam::<AWS_ACCOUNT_ID>:role/vetsoftware-<nombre del environment>`, que es exactamente lo que emite el output `github_iac_role_arns`:

| GitHub Environment | Output | Capacidad |
|---|---|---|
| `iac-plan-dev` | `dev.plan` | Leer infraestructura y state de dev; administrar solo su lockfile. |
| `iac-apply-dev` | `dev.apply` | Aplicar dev y escribir exclusivamente el state de dev. |
| `iac-plan-prod` | `prod.plan` | Leer infraestructura y state de prod; administrar solo su lockfile. |
| `iac-apply-prod` | `prod.apply` | Aplicar prod y escribir exclusivamente el state de prod. |

Los roles `plan` no pueden mutar infraestructura ni escribir el state; solo crean y eliminan su lockfile. Plan y apply inspeccionan exclusivamente el ECR backend de su ambiente. Ningún rol permite `secretsmanager:GetSecretValue`, y cada trust policy exige audiencia `sts.amazonaws.com` y el subject inmutable del repositorio IaC.

Proteja como mínimo `iac-apply-prod` con revisor obligatorio, impida la autoaprobación, limite el despliegue a `main` y mantenga `Wait timer` desactivado salvo que exista una exigencia operativa. Limite `iac-apply-dev` exclusivamente a `develop`: desde que el backend publica su propia imagen dev, el ciclo general y el deploy de imagen de desarrollo nacen de esa rama y dev no necesita `main` para nada. El workflow image-only no recibe secretos de runtime: usa marcadores efímeros de validación y bloquea cualquier cambio fuera de ECS. Mantenga los roles de plan sin permisos AWS de mutación.

`deploy-backend-dev.yml` y `deploy-backend-prod.yml` consumen estos roles para el circuito especializado de imágenes: certifican ECR, ejecutan un plan limitado a ECS, exigen aprobación antes del apply, esperan estabilidad, ejecutan smoke test y revierten al digest anterior cuando es posible.

**Cada entorno tiene sus propios workflows** de bootstrap, plan, apply, drift y despliegue backend, con disparadores, protección, concurrencia e historial independientes. Su configuración se describe en [Automatización del ciclo Terraform](docs/TERRAFORM_AUTOMATION.md).

Al cerrar con merge un PR `release/X.Y.Z` hacia `main`, cada workflow valida nuevamente calidad y versión, publica la imagen antes del tag y asigna dos tags ECR: `X.Y.Z` y `sha-<12 caracteres>`. Una reejecución solo continúa si ambos tags ya apuntan al mismo digest; un estado parcial o conflictivo bloquea la release. Un despacho manual desde cualquier rama distinta de `main` también falla antes de obtener credenciales AWS. El backend publica el digest en el resumen de su run y ahí termina: el despliegue se solicita desde este repositorio, con su propia aprobación. Ningún repositorio de aplicación puede iniciar un cambio en la infraestructura.

La configuración completa, el requisito de baseline y las variables externas pendientes están en [Despliegue inmutable del backend](docs/BACKEND_IMAGE_DEPLOYMENT.md).

Los fronts continúan desplegándose en Cloudflare Pages; los proyectos, dominios y credenciales del entorno dev están documentados en [Cloudflare Pages](docs/CLOUDFLARE_PAGES.md). Sus builds de CI/dev son efímeros y no se publican en ECR; solo las releases productivas conservan una imagen de recuperación. El backend dev publica su propia imagen ARM64 desde `develop` mediante `publish-dev-image.yml`, con tag `dev-<12>` y retención acotada. No necesita ninguna release productiva. Terraform consume ese digest mediante `backend_image_uri`.
