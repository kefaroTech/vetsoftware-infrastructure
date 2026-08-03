# Bootstrap Terraform sin ejecucion local

## Prerrequisitos manuales de una sola vez

En AWS cree o reutilice el proveedor OIDC:

```text
URL:      https://token.actions.githubusercontent.com
Audience: sts.amazonaws.com
```

Cargue `bootstrap/bootstrap-role.yml` como un stack de CloudFormation desde la consola AWS una vez con `Environment=dev`, y otra vez con `Environment=prod`. Marque la confirmacion de creacion de recursos IAM con nombre. La plantilla crea dos roles iniciales distintos:

- `vetsoftware-github-bootstrap-dev`, confiando solo en el GitHub Environment `iac-bootstrap-dev`.
- `vetsoftware-github-bootstrap-prod`, confiando solo en el GitHub Environment `iac-bootstrap-prod`.

Los subjects de confianza deben usar los IDs inmutables:

```text
repo:ORGANIZACION@ORG_ID/vetsoftware-infrastructure@REPO_ID:environment:iac-bootstrap-dev
repo:ORGANIZACION@ORG_ID/vetsoftware-infrastructure@REPO_ID:environment:iac-bootstrap-prod
```

La plantilla limita cada rol a su stack CloudFormation, bucket/KMS, ECR y roles IAM del ambiente. No comparta el rol dev con prod y no almacene access keys en GitHub. El proveedor OIDC debe existir antes de crear estos stacks y se entrega mediante el parametro `GitHubOidcProviderArn`.

## Environments de GitHub

| Environment | Rama | Variable principal |
|---|---|---|
| `iac-bootstrap-dev` | `develop` | `AWS_BOOTSTRAP_ROLE_ARN=...bootstrap-dev` |
| `iac-bootstrap-prod` | `main` | `AWS_BOOTSTRAP_ROLE_ARN=...bootstrap-prod` |

Agregue tambien `AWS_ACCOUNT_ID`, `AWS_REGION`, `GH_ORGANIZATION_ID` y `GH_REPOSITORY_IDS_JSON`. GitHub reserva el prefijo `GITHUB_`, por lo que estas variables configurables usan `GH_`. Dev solo necesita los IDs `backend` e `iac`; prod agrega `private_front` y `public_front`. Produccion debe requerir aprobacion y bloquear autoaprobacion.

## Propiedad por ambiente

| Recurso | Dev | Prod |
|---|---|---|
| Stack de state | `vetsoftware-dev-terraform-state` | `vetsoftware-prod-terraform-state` |
| Bucket | `vetsoftware-dev-tfstate-<cuenta>` | `vetsoftware-prod-tfstate-<cuenta>` |
| State bootstrap | `vetsoftware/bootstrap/terraform.tfstate` en bucket dev | misma key, pero en bucket prod |
| State infraestructura | `vetsoftware/dev/terraform.tfstate` | `vetsoftware/prod/terraform.tfstate` |
| ECR backend | `vetsoftware-dev-backend` | `vetsoftware-backend` |
| Roles Terraform | solo `dev.plan/apply` | solo `prod.plan/apply` |

La key de bootstrap puede tener el mismo texto porque vive en buckets distintos. No existe lectura cruzada entre buckets ni referencias de Terraform entre states.

## Operacion

La primera y las siguientes ejecuciones se lanzan desde **Actions**. El workflow despliega idempotentemente la base CloudFormation, inicializa el backend remoto, genera un plan fresco y aplica ese plan. Si no hay cambios, omite el apply.

No ejecute `terraform init`, `terraform plan` o `terraform apply` contra `bootstrap/` desde una estacion local.
