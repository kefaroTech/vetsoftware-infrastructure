# Despliegue inmutable del backend

## Objetivo

Los workflows `.github/workflows/deploy-backend-dev.yml` y `deploy-backend-prod.yml` reciben una imagen ya publicada, certifican su digest en ECR y despliegan exclusivamente esa imagen en ECS. Nunca transforman un tag mutable en estado deseado de Terraform. Son dos definiciones separadas: cada entorno tiene su propio contrato de identidad del artefacto, su propio grupo de concurrencia y su propio historial de runs.

El contrato de entrada de ambos contiene cuatro datos:

- identificador de la imagen: versión SemVer estricta `X.Y.Z` en producción, o el tag `dev-<12 caracteres del commit>` en desarrollo;
- digest `sha256:<64 hex>`;
- SHA completo del commit del backend;
- URL HTTPS del run que publicó la imagen.

La certificación en ECR depende del entorno. En **producción**, el mismo digest debe contener tanto el tag SemVer como `sha-<12 caracteres del commit>`. En **desarrollo** basta el tag `dev-<12>`, porque no existe release y la identidad del artefacto es el propio commit de `develop`. En los dos casos el escaneo debe estar completo y reportar cero vulnerabilidades High y Critical.

## Flujo protegido

1. El job `plan` usa el environment `iac-plan-<entorno>` y su rol OIDC de lectura.
2. Inicializa la key remota `vetsoftware/<entorno>/terraform.tfstate` y genera un plan fresco.
3. El guard rechaza cualquier cambio fuera de `module.backend.aws_ecs_task_definition.backend` y `module.backend.aws_ecs_service.backend`.
4. El job `apply` espera la aprobación del environment `iac-apply-<entorno>`, vuelve a certificar ECR y genera otro plan fresco con el rol OIDC de escritura.
5. Terraform registra una task definition que usa el repositorio del ambiente por digest; ECS espera estabilidad y su circuit breaker revierte tareas fallidas.
6. El workflow comprueba conteos desired/running/pending, rollout `COMPLETED`, imagen activa exacta y readiness público a través de Cloudflare Tunnel.
7. Si falla la verificación, Terraform intenta volver al digest previamente activo. Si la instalación anterior todavía usaba tags, el circuit breaker conserva la revisión estable y el run falla con una remediación explícita.

Los planes no se publican como artifacts: contienen configuración operativa y se generan dentro del job que los consume. Este workflow no recibe secretos de runtime. Usa marcadores efímeros únicamente para satisfacer las validaciones del root; cualquier intento de cambiar Secrets Manager queda fuera del allowlist ECS y bloquea el run antes del apply.

## Origen de la imagen por entorno

Cada entorno tiene su propio ciclo de artefacto y ninguno espera al otro:

| Entorno | Workflow del backend | Rama | Tag ECR |
|---|---|---|---|
| `dev` | `publish-dev-image.yml` | `develop` | `dev-<12>` en `vetsoftware-dev-backend` |
| `prod` | `publish-release.yml` | `main` (merge de `release/X.Y.Z`) | `X.Y.Z` y `sha-<12>` en `vetsoftware-backend` |

La certificación descrita abajo -doble tag `X.Y.Z` + `sha-<12>` y escaneo sin hallazgos High/Critical- pertenece al circuito de release productiva. La imagen de desarrollo no la exige: se publica desde `develop`, se identifica por su digest y expira con la retención corta de su prefijo.

## Prerrequisito: baseline

Este workflow es intencionalmente `image-only`. Antes de usarlo debe existir un primer `terraform apply` completo y validado para el entorno, incluyendo ECS, RDS, Valkey, secretos, red, observabilidad y el state remoto. Si falta `ecs_cluster_name` o `ecs_service_name`, el despliegue se detiene; no intenta crear toda la plataforma como efecto secundario de una release.

También debe ejecutarse el workflow de bootstrap del mismo ambiente para materializar sus roles OIDC, state y ECR. Dev no requiere que se haya ejecutado el bootstrap prod, ni viceversa.

## Configuración pendiente en GitHub

No se configura todavía ninguna conexión externa. Cuando los repositorios estén publicados, cree estos cuatro environments en `vetsoftware-infrastructure`:

- `iac-plan-dev`
- `iac-apply-dev`
- `iac-plan-prod`
- `iac-apply-prod`

En cada uno configure las variables:

| Variable | Contenido |
|---|---|
| `AWS_ACCOUNT_ID` | Cuenta AWS de 12 dígitos; el workflow arma con ella el ARN del rol plan o apply. |
| `AWS_REGION` | Región AWS; `us-east-1` si se omite. |
| `TF_STATE_BUCKET` | Opcional. Se deriva como `vetsoftware-<ambiente>-tfstate-<cuenta>`; defínala solo para un backend fuera de la convención. |
| `TF_STATE_KMS_KEY_ARN` | Opcional. Se resuelve desde `alias/vetsoftware-<ambiente>-tfstate`; puede quedar vacía con SSE-S3. |
| `API_DOMAIN_NAME` | `dev-api.kefaro.tech` o `api.kefaro.tech`. |
| `CORS_ALLOWED_ORIGINS` | Lista JSON válida de orígenes del entorno. |
| `EMAIL_FROM` | Remitente del backend. |
| `GRAFANA_OTLP_ENDPOINT` | Endpoint OTLP del entorno. |
| `LOGIN_URL` | URL absoluta del login. |
| `PASSWORD_RESET_URL` | URL absoluta de restablecimiento. |
| `REGISTRATION_VERIFICATION_URL` | URL absoluta de verificación. |

Proteja `iac-apply-prod` con revisor obligatorio, sin autoaprobación y limitado a `main`. Limite `iac-apply-dev` exclusivamente a `develop`. La policy OIDC y la regla de deployment branch deben coincidir.

No agregue JWT, tokens Cloudflare ni credenciales Grafana a estos environments para el flujo image-only. Una rotación real de secretos pertenece al workflow general de IaC y debe usar sus propios secrets protegidos y un plan que autorice explícitamente esos recursos.

## Ningún repositorio de aplicación dispara este despliegue

El repositorio `vetsoftware-backend` publica el artefacto y ahí termina su responsabilidad. No existe GitHub App, token cruzado ni `workflow_dispatch` remoto: su workflow deja los cuatro datos en el Summary del run de publicación y quien opera la infraestructura los copia al lanzar el workflow correspondiente desde `vetsoftware-infrastructure`.

Esto mantiene una sola dirección de confianza. El repositorio IaC concede a los repositorios de aplicación permiso para publicar en ECR mediante roles OIDC de mínimo privilegio; ninguno de ellos obtiene la capacidad inversa de iniciar un cambio en la infraestructura.

## Operación manual y auditoría

Ambos workflows se inician manualmente desde Actions con sus cuatro inputs. Cada job escribe en su Summary la versión, el digest, el commit, el run de origen y los recursos incluidos en el plan. La concurrencia se serializa dentro de cada entorno mediante `terraform-<entorno>` y nunca cancela un apply en curso; los dos entornos avanzan sin esperarse.

No use este workflow para cambios generales de infraestructura. Red, base de datos, cache, seguridad, secretos o capacidad requieren su propio PR, plan revisado y apply controlado.
