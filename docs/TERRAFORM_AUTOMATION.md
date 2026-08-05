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
| `Deploy backend image dev` | Manual | Roles dev | Certifica y despliega desde `vetsoftware-dev-backend`. Input unico: la version `X.Y.Z-dev.N`. |
| `Deploy backend image prod` | Manual | Roles prod | Certifica y despliega desde `vetsoftware-backend`. Input unico: la release `X.Y.Z`. |

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

- `AWS_ACCOUNT_ID`
- `TF_VARS_JSON` opcional
- `AWS_REGION`
- `API_DOMAIN_NAME`
- `CORS_ALLOWED_ORIGINS`
- `EMAIL_FROM`
- `GRAFANA_OTLP_ENDPOINT`
- `LOGIN_URL`
- `PASSWORD_RESET_URL`
- `REGISTRATION_VERIFICATION_URL`
- `BACKEND_IMAGE_URI` para el primer apply

`BACKEND_IMAGE_URI` solo hace falta en el Environment de apply y solo hasta que
exista el servicio ECS: desde el segundo ciclo el script hereda el digest de la
task definition viva. Plan y drift no la necesitan nunca. Cuando el state esta
vacio y el ECR todavia no publica nada, el plan usa un digest marcador para
poder revisarse igual y lo anuncia como advertencia; el apply sigue exigiendo un
digest real.

El rol OIDC, el bucket y la KMS key del state no se configuran: se derivan de la
convencion que fija `bootstrap/state-backend.yml`. Cada workflow arma el ARN como
`arn:aws:iam::<AWS_ACCOUNT_ID>:role/vetsoftware-iac-<funcion>-<ambiente>`, y
`terraform-cycle.ps1` resuelve el bucket como
`vetsoftware-<ambiente>-tfstate-<cuenta>` via `sts:GetCallerIdentity` y la key
desde el alias `alias/vetsoftware-<ambiente>-tfstate`. Definir `TF_STATE_BUCKET` o
`TF_STATE_KMS_KEY_ARN` sigue funcionando y tiene prioridad sobre lo derivado; solo
hace falta cuando el backend no sigue la convencion.

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

## Lock de state huerfano

Un apply cancelado deja el `.tflock` en S3 y todo ciclo posterior muere tras agotar
el `-lock-timeout=5m` con `Error acquiring the state lock`. `Terraform unlock dev`
(`workflow_dispatch` desde `develop`) libera ese lock: recibe como input el `ID` que
imprime el error y ejecuta `terraform force-unlock` con el rol de apply, que ya tiene
`s3:DeleteObject` sobre el `.tflock` de su ambiente.

Tres frenos evitan que libere un lock vivo: `force-unlock` compara el ID contra el
lock existente y falla si no coincide, el workflow comparte el grupo de concurrencia
`terraform-<ambiente>` con plan, apply y drift, y pasa por el Environment de apply
con su aprobacion.

Antes de desbloquear, confirme en Actions que ninguna ejecucion siga en curso. Y
tenga presente que un apply cortado a la mitad pudo crear recursos que no quedaron
registrados: revise el plan siguiente antes de aplicarlo.

Prod no tiene un workflow equivalente; su desbloqueo se hace a mano y de forma
deliberada.

## Servicio ECS huerfano

Liberar el lock no alcanza cuando el apply se corto a mitad de `CreateService`: el
servicio queda vivo en ECS y fuera del state, el ciclo siguiente lo replanea como
create y ECS responde `Creation of service was not idempotent`.

Es el unico recurso del stack que sufre esto de forma realista. La task definition
crea revisiones aditivas, los roles del modulo usan `name_prefix`, y el presupuesto y
los schedules tienen nombre fijo pero se crean en menos de un segundo. El servicio, en
cambio, mantiene el create abierto entre cuatro y seis minutos por
`wait_for_steady_state = true`, y esa es la ventana en la que cabe una cancelacion.

`terraform-cycle.ps1` lo reconcilia solo: antes de generar el plan compara el state
contra ECS y, si el servicio existe `ACTIVE` en AWS pero no en el state, lo adopta con
`terraform import`. El plan resultante es un update en lugar de un create. La adopcion
solo ocurre en `-Mode Apply`; plan y drift se limitan a reportar el huerfano en el step
summary, porque nunca mutan el state.

Se importa en lugar de borrar por dos razones. La primera es que el script lo comparten
dev y prod, y un borrado desatendido ante un falso positivo tumbaria el servicio
productivo. La segunda es que el output `ecs_service_name` depende del propio servicio:
mientras falta del state, `Set-CurrentBackendImage` no puede leer la imagen en ejecucion
y cae al respaldo `BACKEND_IMAGE_URI`, que puede ser un digest viejo. Adoptarlo
restituye el output y el ciclo vuelve a conservar la imagen desplegada.

Dos casos que el paso no resuelve. Si el servicio quedo en `DRAINING`, ECS todavia
rechaza el nombre y no hay nada que importar: el ciclo avisa y hay que reintentar en
unos minutos. Si quedo `INACTIVE`, no estorba, porque ECS permite reusar el nombre.

## Forzar la imagen del backend

El ciclo general nunca cambia la imagen: `Set-CurrentBackendImage` lee la que el
servicio ECS tiene en ejecucion y la fija, de modo que un `apply` de infraestructura no
puede revertir un despliegue. Los cambios de imagen van por `deploy-backend-dev/prod`,
que recibe **solo la version** como input —`X.Y.Z-dev.N` en dev, `X.Y.Z` en prod—,
resuelve el digest desde ese tag y valida tags, escaneo y que la version no retroceda
respecto de la que esta corriendo (salvo `allow_rollback`).

Ese diseño se atasca cuando la imagen en ejecucion esta rota. El servicio no alcanza
steady state, el apply falla, y el apply siguiente vuelve a heredar la misma imagen
rota. Y el circuito de imagen no puede rescatarlo: su guard rechaza cualquier plan con
cambios fuera de la task definition y el servicio, asi que basta con que quede un
recurso pendiente —por ejemplo los `aws_scheduler_schedule`, que dependen del propio
servicio— para que tampoco pueda correr. Las dos vias se bloquean entre si.

Para eso existe el input opcional `backend_image_uri` en `Terraform apply dev/prod`.
Cuando se pasa un digest, el ciclo lo fija y se salta la lectura de ECS; vacio, el
comportamiento es el de siempre. El valor viaja como variable de entorno
`FORCE_BACKEND_IMAGE_URI` y el script lo valida contra el patron del ECR **del
ambiente**, de modo que un digest de dev no puede aplicarse en prod ni al reves, y solo
se aceptan referencias por digest inmutable, nunca por tag.

Es una salida de emergencia, no la via normal: no certifica tags ni escaneo, cosa que
`deploy-backend-*` si hace. Usela para desatascar y vuelva al circuito de imagen en
cuanto el ambiente converja.

Relacionado: `Set-CurrentBackendImage` solo hereda de un servicio en estado `ACTIVE`.
Un servicio borrado sigue visible como `INACTIVE` cerca de una hora conservando su
ultima task definition, y sin ese filtro el ciclo resucitaba la imagen de un servicio
que ya no existia.
