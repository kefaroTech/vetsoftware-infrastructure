# Automatizacion del ciclo Terraform

**Cada entorno tiene sus propios workflows.** No existe ningun archivo compartido que reciba el entorno como parametro: `dev` y `prod` tienen definiciones, disparadores, historial de runs y alcance de validacion separados, de modo que un fallo de un entorno nunca bloquea el ciclo del otro. El bootstrap queda fuera del ciclo automatizado: crea el proveedor OIDC, el backend y los propios roles, por lo que conserva su procedimiento administrativo controlado.

| Workflow | Disparador | Credencial AWS | Efecto |
|---|---|---|---|
| `Terraform quality dev` | PR y push a `develop` | Ninguna | Gate acotado a `environments/dev`. |
| `Terraform quality prod` | PR y push a `main` | Ninguna | Gate acotado a `environments/prod`. |
| `Terraform quality platform` | PR y push que toquen `bootstrap/`, `modules/ecr/`, `modules/github_iac_roles/` o los scripts del gate | Ninguna | Gate de la plataforma comun que ambos entornos consumen. |
| `Terraform plan dev` | PR a `develop` o manual | `iac-plan-dev` | Publica un comentario actualizable con el plan de dev; nunca aplica. |
| `Terraform plan prod` | PR a `main` o manual | `iac-plan-prod` | Igual para prod. |
| `Terraform apply dev` | Manual | `iac-apply-dev` | Exige `refs/heads/develop`, espera la proteccion del environment, crea un plan nuevo y aplica exactamente ese archivo. |
| `Terraform apply prod` | Manual | `iac-apply-prod` | Igual, exigiendo `refs/heads/main`. |
| `Terraform drift dev` | Diario a las 11:17 UTC o manual | `iac-plan-dev` | `plan -refresh-only -detailed-exitcode`; el drift hace fallar el job y nunca dispara apply. |
| `Terraform drift prod` | Diario a las 11:47 UTC o manual | `iac-plan-prod` | Igual para prod, en su propio run. |
| `Deploy backend image dev` | Manual | `iac-plan-dev` y `iac-apply-dev` | Circuito de imagen de desarrollo; certifica el tag `dev-<12>`. |
| `Deploy backend image prod` | Manual | `iac-plan-prod` y `iac-apply-prod` | Circuito de imagen productiva; certifica `X.Y.Z` y `sha-<12>`. |

El unico elemento compartido entre los workflows de un mismo entorno es el grupo de concurrencia `terraform-<entorno>`, y existe precisamente para serializar plan, apply, drift y despliegue de imagen sobre el mismo state. Los grupos `terraform-dev` y `terraform-prod` son independientes entre si: una operacion en un entorno nunca espera a la del otro.

El gate acotado por entorno tiene una consecuencia deliberada: `terraform fmt` sigue revisando todo el repositorio en cada job, pero TFLint, `validate`, los contratos y Trivy solo cubren las raices del entorno correspondiente. Un cambio en `environments/prod` integrado desde `develop` se valida cuando llega a su PR hacia `main`, no antes.

## GitHub Environments

Cree los cuatro environments emitidos por `terraform -chdir=bootstrap output github_iac_environments` y configure `AWS_IAC_ROLE_ARN` con el ARN correspondiente:

| Environment | Rama o uso autorizado | Proteccion minima |
|---|---|---|
| `iac-plan-dev` | PR hacia `develop`, ejecucion manual y drift desde la rama por defecto | Sin secretos de runtime; rol OIDC `dev.plan`. |
| `iac-plan-prod` | PR hacia `main`, ejecucion manual y drift desde la rama por defecto | Sin secretos de runtime; rol OIDC `prod.plan`. |
| `iac-apply-dev` | Exclusivamente `develop`, tanto para el ciclo general como para el deploy de imagen | Limitar deployment branches a `develop`. |
| `iac-apply-prod` | Exclusivamente `main` | Revisor obligatorio, impedir autoaprobacion y limitar deployment branches a `main`. |

La trust policy OIDC exige audiencia `sts.amazonaws.com`, repositorio/organizacion por nombre e ID inmutables y el nombre exacto del GitHub Environment. Los roles de plan solo leen infraestructura y state -salvo el lockfile S3 requerido por Terraform-; solo los roles de apply escriben state y recursos del entorno.

## Variables y secretos

Configure estas variables en cada uno de los cuatro GitHub Environments, con valores propios de `dev` o `prod`:

- `AWS_IAC_ROLE_ARN`
- `TF_STATE_BUCKET`
- `TF_STATE_KMS_KEY_ARN` cuando el state usa KMS
- `TF_VARS_JSON` (opcional) como objeto JSON con cualquier override no sensible que difiera de los defaults del root
- `AWS_REGION` (opcional; el valor predeterminado es `us-east-1`)
- `API_DOMAIN_NAME`
- `CORS_ALLOWED_ORIGINS` como lista JSON de Terraform
- `EMAIL_FROM`
- `GRAFANA_OTLP_ENDPOINT`
- `LOGIN_URL`
- `PASSWORD_RESET_URL`
- `REGISTRATION_VERIFICATION_URL`
- `BACKEND_IMAGE_URI` solo para el primer despliegue; cuando ya existe baseline, el workflow conserva el digest activo de ECS y evita interferir con el deploy especializado de imagen

`TF_VARS_JSON` permite mantener en el environment, por ejemplo, capacidad, presupuesto y horarios no predeterminados. El ejecutor rechaza `application_secrets_json`, `grafana_secrets_json`, `cloudflare_tunnel_token`, `backend_image_uri` y `environment` dentro de ese objeto: los secretos usan GitHub Secrets, la imagen la conserva el circuito especializado y el entorno lo fija el workflow.

Configure ademas estos secretos unicamente en `iac-apply-dev` e `iac-apply-prod`:

- `APPLICATION_SECRETS_JSON`
- `CLOUDFLARE_TUNNEL_TOKEN`
- `GRAFANA_SECRETS_JSON`

Plan y drift usan marcadores efimeros para los argumentos write-only y nunca reciben los secretos de runtime. Apply recibe los valores reales solo despues de superar la proteccion del environment.

## Flujo operativo

1. Un PR hacia `develop` dispara `Terraform plan dev`; un PR de release hacia `main` dispara `Terraform plan prod`. El comentario se actualiza en cada ejecucion y el resumen del job conserva el mismo contenido.
2. Tras integrar, ejecute `Terraform apply dev` desde `develop` o `Terraform apply prod` desde `main`.
3. En produccion, GitHub detiene el job antes de entregar el token OIDC y los secretos hasta que un revisor autorizado aprueba el environment.
4. Una vez aprobado, el mismo job inicializa el state, genera el plan con `-detailed-exitcode` y aplica ese archivo local inmediatamente. No descarga ni acepta planes de PR o de ejecuciones anteriores.
5. Revise cualquier fallo diario de `Terraform drift dev` o `Terraform drift prod`. Un exit code `2` significa drift detectado; debe corregirse mediante un PR y el apply protegido, nunca desde el workflow programado.

En las reglas de proteccion de `develop` marque como checks requeridos `Terraform quality dev` y `Terraform plan dev`; en las de `main`, `Terraform quality prod` y `Terraform plan prod`. Agregue `Terraform quality platform` a ambas. Los PR desde forks no reciben OIDC y el job de plan se omite deliberadamente.
