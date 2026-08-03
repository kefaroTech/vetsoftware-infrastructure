# Automatizacion del ciclo Terraform

El ciclo general de los roots `environments/dev` y `environments/prod` esta separado en cuatro workflows. El bootstrap queda fuera deliberadamente: crea el proveedor OIDC, el backend y los propios roles, por lo que conserva su procedimiento administrativo controlado.

| Workflow | Disparador | Credencial AWS | Efecto |
|---|---|---|---|
| `Terraform quality` | PR y push a `develop`/`main` | Ninguna | Formato, lint, validate, contratos y seguridad IaC. |
| `Terraform plan` | PR a `develop`/`main` o manual | `iac-plan-<entorno>` | Publica un comentario actualizable con el plan; nunca aplica. |
| `Terraform apply` | Manual | `iac-apply-<entorno>` | Exige la rama GitFlow, espera la proteccion del environment, crea un plan nuevo y aplica exactamente ese archivo. |
| `Terraform drift` | Diario a las 11:17 UTC o manual | `iac-plan-<entorno>` | Ejecuta `plan -refresh-only -detailed-exitcode`; el drift hace fallar el job y nunca dispara apply. |

Los workflows operativos comparten el grupo de concurrencia `terraform-<entorno>`, incluido el despliegue especializado de imagen. Una operacion espera a la anterior para evitar planes o escrituras simultaneas sobre el mismo state.

## GitHub Environments

Cree los cuatro environments emitidos por `terraform -chdir=bootstrap output github_iac_environments` y configure `AWS_IAC_ROLE_ARN` con el ARN correspondiente:

| Environment | Rama o uso autorizado | Proteccion minima |
|---|---|---|
| `iac-plan-dev` | PR hacia `develop`, ejecucion manual y drift desde la rama por defecto | Sin secretos de runtime; rol OIDC `dev.plan`. |
| `iac-plan-prod` | PR hacia `main`, ejecucion manual y drift desde la rama por defecto | Sin secretos de runtime; rol OIDC `prod.plan`. |
| `iac-apply-dev` | `develop` para el ciclo general y `main` para el deploy especializado de imagen | Limitar deployment branches a `develop` y `main`. |
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

1. Un PR hacia `develop` planifica `dev`; un PR de release hacia `main` planifica `prod`. El comentario se actualiza en cada ejecucion y el resumen del job conserva el mismo contenido.
2. Tras integrar, ejecute `Terraform apply` desde `develop` para `dev` o desde `main` para `prod`.
3. En produccion, GitHub detiene el job antes de entregar el token OIDC y los secretos hasta que un revisor autorizado aprueba el environment.
4. Una vez aprobado, el mismo job inicializa el state, genera el plan con `-detailed-exitcode` y aplica ese archivo local inmediatamente. No descarga ni acepta planes de PR o de ejecuciones anteriores.
5. Revise cualquier fallo diario de `Terraform drift`. Un exit code `2` significa drift detectado; debe corregirse mediante un PR y el apply protegido, nunca desde el workflow programado.

Marque `Terraform quality` y `Terraform plan` como checks requeridos en las reglas de proteccion de `develop` y `main`. Los PR desde forks no reciben OIDC y el job de plan se omite deliberadamente.
