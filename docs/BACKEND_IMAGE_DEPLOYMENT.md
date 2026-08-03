# Despliegue inmutable del backend

## Objetivo

El workflow `.github/workflows/deploy-backend.yml` recibe una release ya publicada, certifica su digest en ECR y despliega exclusivamente esa imagen en ECS. Nunca transforma un tag mutable en estado deseado de Terraform.

El contrato de entrada contiene:

- entorno `dev` o `prod`;
- versión SemVer estricta `X.Y.Z`;
- digest `sha256:<64 hex>`;
- SHA completo del commit del backend;
- URL HTTPS del run que publicó la imagen.

ECR debe demostrar que el mismo digest contiene tanto el tag SemVer como `sha-<12 caracteres del commit>`. El escaneo debe estar completo y reportar cero vulnerabilidades High y Critical.

## Flujo protegido

1. El job `plan` usa el environment `iac-plan-<entorno>` y su rol OIDC de lectura.
2. Inicializa la key remota `vetsoftware/<entorno>/terraform.tfstate` y genera un plan fresco.
3. El guard rechaza cualquier cambio fuera de `module.backend.aws_ecs_task_definition.backend` y `module.backend.aws_ecs_service.backend`.
4. El job `apply` espera la aprobación del environment `iac-apply-<entorno>`, vuelve a certificar ECR y genera otro plan fresco con el rol OIDC de escritura.
5. Terraform registra una task definition que usa `vetsoftware-backend@sha256:...`; ECS espera estabilidad y su circuit breaker revierte tareas fallidas.
6. El workflow comprueba conteos desired/running/pending, rollout `COMPLETED`, imagen activa exacta y readiness público a través de Cloudflare Tunnel.
7. Si falla la verificación, Terraform intenta volver al digest previamente activo. Si la instalación anterior todavía usaba tags, el circuit breaker conserva la revisión estable y el run falla con una remediación explícita.

Los planes no se publican como artifacts: contienen configuración operativa y se generan dentro del job que los consume. Este workflow no recibe secretos de runtime. Usa marcadores efímeros únicamente para satisfacer las validaciones del root; cualquier intento de cambiar Secrets Manager queda fuera del allowlist ECS y bloquea el run antes del apply.

## Origen de la imagen por entorno

Cada entorno tiene su propio ciclo de artefacto y ninguno espera al otro:

| Entorno | Workflow del backend | Rama | Tag ECR |
|---|---|---|---|
| `dev` | `publish-dev-image.yml` | `develop` | `dev-<12 caracteres del commit>` |
| `prod` | `publish-release.yml` | `main` (merge de `release/X.Y.Z`) | `X.Y.Z` y `sha-<12>` |

La certificación descrita abajo -doble tag `X.Y.Z` + `sha-<12>` y escaneo sin hallazgos High/Critical- pertenece al circuito de release productiva. La imagen de desarrollo no la exige: se publica desde `develop`, se identifica por su digest y expira con la retención corta de su prefijo.

## Prerrequisito: baseline

Este workflow es intencionalmente `image-only`. Antes de usarlo debe existir un primer `terraform apply` completo y validado para el entorno, incluyendo ECS, RDS, Valkey, secretos, red, observabilidad y el state remoto. Si falta `ecs_cluster_name` o `ecs_service_name`, el despliegue se detiene; no intenta crear toda la plataforma como efecto secundario de una release.

También debe aplicarse `bootstrap` para materializar los roles OIDC y sus permisos de lectura de `vetsoftware-backend`. La preparación del código no crea recursos en AWS.

## Configuración pendiente en GitHub

No se configura todavía ninguna conexión externa. Cuando los repositorios estén publicados, cree estos cuatro environments en `VetSoftwareIaC`:

- `iac-plan-dev`
- `iac-apply-dev`
- `iac-plan-prod`
- `iac-apply-prod`

En cada uno configure las variables:

| Variable | Contenido |
|---|---|
| `AWS_IAC_ROLE_ARN` | ARN de plan o apply correspondiente generado por bootstrap. |
| `AWS_REGION` | Región AWS; `us-east-1` si se omite. |
| `TF_STATE_BUCKET` | Output `state_bucket_name` de bootstrap. |
| `TF_STATE_KMS_KEY_ARN` | Output `state_kms_key_arn`; puede quedar vacío con SSE-S3. |
| `API_DOMAIN_NAME` | `dev-api.kefaro.tech` o `api.kefaro.tech`. |
| `CORS_ALLOWED_ORIGINS` | Lista JSON válida de orígenes del entorno. |
| `EMAIL_FROM` | Remitente del backend. |
| `GRAFANA_OTLP_ENDPOINT` | Endpoint OTLP del entorno. |
| `LOGIN_URL` | URL absoluta del login. |
| `PASSWORD_RESET_URL` | URL absoluta de restablecimiento. |
| `REGISTRATION_VERIFICATION_URL` | URL absoluta de verificación. |

Proteja `iac-apply-prod` con revisor obligatorio, sin autoaprobación y limitado a `main`. Limite `iac-apply-dev` a `main` para este workflow manual, o cree posteriormente un flujo de promoción dev desde `develop` con una trust policy específica. La policy OIDC y la regla de deployment branch deben coincidir: una diferencia bloquea correctamente la asunción del rol.

No agregue JWT, tokens Cloudflare ni credenciales Grafana a estos environments para el flujo image-only. Una rotación real de secretos pertenece al workflow general de IaC y debe usar sus propios secrets protegidos y un plan que autorice explícitamente esos recursos.

## Conexión desde el backend, pendiente

Cree una GitHub App de la organización con permiso `Actions: read and write`, instálela únicamente en `VetSoftwareIaC` y guarde en el environment `production` de `VetSoftware`:

- variable `IAC_DISPATCH_CLIENT_ID`;
- secret `IAC_DISPATCH_PRIVATE_KEY`.

Opcionalmente defina `IAC_GITHUB_OWNER` e `IAC_GITHUB_REPOSITORY`; los valores predeterminados son `kefaroTech` y `VetSoftwareIaC`. La política de Actions debe permitir `actions/create-github-app-token`, siempre fijada a un SHA completo.

Hasta completar esta sección, publicar una release fallará de forma segura en el paso de creación del token: la imagen y la GitHub Release serán idempotentes y una reejecución podrá solicitar el despliegue después de configurar la App.

## Operación manual y auditoría

`deploy-backend.yml` también puede iniciarse manualmente desde Actions con los cinco inputs. Cada job escribe en su Summary el entorno, versión, digest, commit, run de origen y recursos incluidos en el plan. La concurrencia se serializa por entorno y nunca cancela un apply en curso.

No use este workflow para cambios generales de infraestructura. Red, base de datos, cache, seguridad, secretos o capacidad requieren su propio PR, plan revisado y apply controlado.
