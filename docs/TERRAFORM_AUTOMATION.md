# Automatizacion del ciclo Terraform

Todo Terraform se ejecuta en GitHub Actions. `dev` y `prod` tienen bootstrap, state, identidad, pipelines operativos, concurrencia e historial de runs independientes. Ningun workflow necesita credenciales AWS permanentes ni un `terraform apply` local.

## Bootstrap independiente

| Workflow | Rama | GitHub Environment | State de bootstrap | Recursos creados |
|---|---|---|---|---|
| `Terraform bootstrap dev` | `develop` | `iac-bootstrap-dev` | `vetsoftware-dev-tfstate-<cuenta>/vetsoftware/bootstrap/terraform.tfstate` | KMS, ECR `vetsoftware-dev-backend`, roles plan/apply de dev y rol publicador development. |
| `Terraform bootstrap prod` | `main` | `iac-bootstrap-prod` | `vetsoftware-prod-tfstate-<cuenta>/vetsoftware/bootstrap/terraform.tfstate` | KMS, ECR productivos y roles plan/apply de prod y publicadores production. |

Cada workflow crea primero su backend remoto mediante un stack CloudFormation propio y luego inicializa Terraform directamente contra ese backend. CloudFormation conserva bucket y KMS aunque el stack se elimine. No existe state local ni migracion entre ambientes.

El proveedor `token.actions.githubusercontent.com` es un prerrequisito externo de la cuenta, no un recurso propiedad de dev o prod. Cree ademas dos roles iniciales distintos: uno confia exclusivamente en `iac-bootstrap-dev` y el otro exclusivamente en `iac-bootstrap-prod`.

Configure en ambos GitHub Environments:

- `AWS_BOOTSTRAP_ROLE_ARN`: rol inicial exclusivo del ambiente.
- `AWS_ACCOUNT_ID`: cuenta AWS esperada; `configure-aws-credentials` rechaza otra cuenta.
- `AWS_REGION`: `us-east-1` si no se define otro valor.
- `GH_ORGANIZATION_ID`: ID numerico inmutable del propietario.
- `GH_REPOSITORY_IDS_JSON`: dev requiere `backend` e `iac`; prod requiere ademas `private_front` y `public_front`. Se usa `GH_` porque GitHub no permite crear variables con el prefijo reservado `GITHUB_`.

Ejemplo de `GH_REPOSITORY_IDS_JSON`:

```json
{
  "backend": "100000001",
  "private_front": "100000002",
  "public_front": "100000003",
  "iac": "100000004"
}
```

Proteja `iac-bootstrap-dev` para aceptar solo `develop`. Proteja `iac-bootstrap-prod` para aceptar solo `main`, exigir revisor e impedir autoaprobacion. Los dos workflows son manuales, generan un plan fresco y aplican exactamente ese archivo despues de obtener la autorizacion del Environment.

## Ciclo operativo

| Workflow | Disparador | Credencial AWS | Efecto |
|---|---|---|---|
| `Terraform quality dev` | PR y push a `develop` | Ninguna | Gate acotado a `environments/dev`. |
| `Terraform quality prod` | PR y push a `main` | Ninguna | Gate acotado a `environments/prod`. |
| `Terraform quality bootstrap dev` | PR y push a `develop` que toquen bootstrap o identidad | Ninguna | Valida el codigo de bootstrap en el ciclo dev. |
| `Terraform quality bootstrap prod` | PR y push a `main` que toquen bootstrap o identidad | Ninguna | Validacion productiva independiente. |
| `Terraform plan dev` | PR a `develop` o manual | `iac-plan-dev` | Plan visible de dev; nunca aplica. |
| `Terraform plan prod` | PR a `main` o manual | `iac-plan-prod` | Plan visible de prod; nunca aplica. |
| `Terraform apply dev` | Manual desde `develop` | `iac-apply-dev` | Plan fresco y apply exclusivo de dev. |
| `Terraform apply prod` | Manual desde `main` | `iac-apply-prod` | Plan fresco y apply protegido de prod. |
| `Terraform drift dev` | Diario a las 11:17 UTC o manual | `iac-plan-dev` | `plan -refresh-only -detailed-exitcode`, sin apply. |
| `Terraform drift prod` | Diario a las 11:47 UTC o manual | `iac-plan-prod` | Igual para prod, en su propio run. |
| `Deploy backend image dev` | Manual | Roles dev | Certifica y despliega desde `vetsoftware-dev-backend`. |
| `Deploy backend image prod` | Manual | Roles prod | Certifica y despliega desde `vetsoftware-backend`. |

Los grupos `terraform-bootstrap-dev`, `terraform-bootstrap-prod`, `terraform-dev` y `terraform-prod` son distintos. Un bloqueo, fallo o apply de un ambiente nunca hace esperar al otro.

## GitHub Environments operativos

Cada bootstrap emite solamente los roles de su ambiente:

| Environment | Rama autorizada | Rol |
|---|---|---|
| `iac-plan-dev` | PR/manual de dev | `dev.plan` |
| `iac-apply-dev` | `develop` | `dev.apply` |
| `iac-plan-prod` | PR/manual de prod | `prod.plan` |
| `iac-apply-prod` | `main` | `prod.apply` |

Configure en plan y apply del ambiente correspondiente:

- `AWS_IAC_ROLE_ARN`
- `TF_STATE_BUCKET`
- `TF_STATE_KMS_KEY_ARN`
- `TF_VARS_JSON` opcional
- `AWS_REGION`
- `API_DOMAIN_NAME`
- `CORS_ALLOWED_ORIGINS`
- `EMAIL_FROM`
- `GRAFANA_OTLP_ENDPOINT`
- `LOGIN_URL`
- `PASSWORD_RESET_URL`
- `REGISTRATION_VERIFICATION_URL`
- `BACKEND_IMAGE_URI` para el primer despliegue

Configure unicamente en los Environments de apply:

- `APPLICATION_SECRETS_JSON`
- `CLOUDFLARE_TUNNEL_TOKEN`
- `GRAFANA_SECRETS_JSON`

## Primera ejecucion

1. Ejecute `Terraform bootstrap dev` desde `develop` o `Terraform bootstrap prod` desde `main`.
2. Copie sus outputs al Environment `iac-plan-*`, `iac-apply-*` y al Environment publicador de la aplicacion correspondiente.
3. Publique una imagen inmutable del backend en el ECR del mismo ambiente.
4. Ejecute `Terraform plan dev/prod`.
5. Revise el plan y ejecute `Terraform apply dev/prod`.

Dev puede completar los cinco pasos sin que exista prod, y prod puede hacer lo mismo sin que exista dev.

## Ejecuciones posteriores

Los cambios generales siguen PR, quality, plan, merge y apply manual. El bootstrap solo vuelve a ejecutarse cuando cambian su ECR, sus roles o su backend. Drift detecta cambios externos y falla con exit code `2`, pero nunca corrige automaticamente.
