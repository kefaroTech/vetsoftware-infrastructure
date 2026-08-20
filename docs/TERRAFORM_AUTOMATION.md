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
| `Terraform quality dev` | PR a `develop`, con filtro de rutas, o manual | Ninguna | Gate de `environments/dev` mas `bootstrap`, `modules/ecr`, `modules/github_iac_roles` y `modules/log_shipping`. |
| `Terraform quality prod` | PR y push a `main`, sin filtro de rutas, o manual | Ninguna | Las mismas raices compartidas, con `environments/prod` en lugar de dev. |
| `Terraform plan dev` | PR a `develop` o manual | `iac-plan-dev` | Plan visible de dev; nunca aplica. |
| `Terraform plan prod` | PR a `main` o manual | `iac-plan-prod` | Plan visible de prod; nunca aplica. |
| `Terraform apply dev` | Manual desde `develop` | `iac-apply-dev` | Plan fresco y apply exclusivo de dev. |
| `Terraform apply prod` | Manual desde `main` | `iac-apply-prod` | Plan fresco y apply protegido de prod. |
| `Terraform drift dev` | Diario a las 11:17 UTC o manual | `iac-plan-dev` | `plan -refresh-only -detailed-exitcode`, sin apply, con triage y aviso por issue. |
| `Terraform drift prod` | Manual desde `main`; el cron diario de las 11:47 UTC se salta mientras `PROD_DRIFT_ENABLED` no valga `true` | `iac-plan-prod` | Igual para prod, en su propio run. Ver «Por que el drift de prod nace gateado». |
| `Start dev environment` | Manual | Roles dev | Arranca la RDS y deja el servicio en una tarea. Unica forma de encender dev: no hay arranque programado. Avisa el desenlace en Slack. |
| `Stop dev environment` | Manual | Roles dev | Baja el servicio a cero y detiene la RDS, lo mismo que el apagado programado. Avisa el desenlace en Slack. |
| `Deploy backend image dev` | Manual | Roles dev | Certifica y despliega desde `vetsoftware-dev-backend`. Input unico: la version `X.Y.Z-dev.N`. Avisa el desenlace en Slack. |
| `Deploy backend image prod` | Manual | Roles prod | Certifica y despliega desde `vetsoftware-backend`. Input unico: la release `X.Y.Z`. |

Los grupos `terraform-bootstrap-dev`, `terraform-bootstrap-prod`, `terraform-dev` y `terraform-prod` son distintos. Un bloqueo, fallo o apply de un ambiente nunca hace esperar al otro.

## El vigilante de deriva: por qué filtra y a quién avisa

Entre el 7 y el 16 de agosto de 2026 el drift de dev encadenó **diez ciclos en rojo**. Los cuatro últimos (5-6 s) fueron el bloqueo de facturación de Actions; los seis anteriores (44 s a 1 m 36 s) arrancaron, planificaron y fallaron de verdad. Nadie los miró, porque el workflow **no avisaba a ningún sitio** y porque los seis decían casi lo mismo. Escondido entre ese «casi» iba un hallazgo real: `module.monitoring.aws_sns_topic_subscription.email[0] has been deleted`, es decir, las alarmas de dev llevaban desde el 7 de agosto sin destinatario de correo.

De ahí salen las dos piezas que hoy envuelven al ciclo:

- **`scripts/quality/drift-triage.ps1`** ejecuta el mismo `plan -refresh-only` de siempre —nunca un apply— y clasifica lo que sale. Silencia únicamente cuatro pares dirección/atributo, cada uno con su motivo escrito en la tabla del propio script: `desired_count` del servicio ECS y `status`/`latest_restorable_time` de la RDS, que los mueve el apagado programado de EventBridge, e `inline_policy` del rol y `layers` de la Lambda de `module.cost_report`, que los reescribe el proveedor de AWS en cada lectura. Todo lo demás deja el job en rojo. El criterio es de **denegación por defecto**: dirección desconocida, atributo no listado, objeto borrado, deriva que el clasificador no supo leer o fallo del ciclo son rojo. Un objeto borrado nunca se silencia, por conocida que sea la dirección.
- **`scripts/quality/drift-alert.ps1`** convierte el rojo en un aviso. Abre —o comenta— **un issue por ambiente** con el veredicto, el detalle y qué hacer con él, y publica además en Slack si recibe la URL del webhook. Es idempotente: mantiene un único issue abierto y no repite el mismo veredicto dentro de 20 horas.

No se usó `ignore_changes` en los módulos a propósito: eso apagaría también el `apply`, que es justo donde esos atributos tienen que reconciliarse. El filtro vive en el informe, no en la infraestructura.

El aviso va por issue y no por Slack porque el webhook `VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL` vive hoy en el environment `iac-apply-dev`, y el drift corre con `iac-plan-dev`, que **no tiene ningún secret**. La expresión está declarada en el workflow: copiar el secret al environment de plan enciende ese canal sin tocar nada más.

### Por qué el drift de prod nace gateado

`terraform-drift-prod.yml` se borró en agosto tras 14 ejecuciones y 0 éxitos, y el diagnóstico era correcto: los `cron` de GitHub corren **siempre sobre la rama por defecto** —aquí `develop`— y la *deployment branch policy* de `iac-plan-prod` sólo admite `main`, así que el job se rechazaba antes del primer paso. Verificado de nuevo contra la API el 19 de agosto de 2026, con dos bloqueos más:

- El rol `vetsoftware-iac-plan-prod` sólo acepta dos sujetos OIDC (`modules/github_iac_roles/main.tf:290-293`): el del environment y el de un job de `pull_request` sin environment. Un `schedule` sin environment tiene sujeto `ref:refs/heads/develop` y **no** puede asumirlo, así que soltar el environment tampoco arregla nada.
- No existe **ninguna** variable de prod, ni en el repositorio ni en `iac-plan-prod`.

Por eso el fichero está repuesto pero su `cron` va condicionado a la variable de repositorio `PROD_DRIFT_ENABLED`. Mientras no valga `true`, la ejecución programada se **salta** en lugar de fallar: un rojo diario que nadie puede arreglar desde el repositorio es exactamente el ruido que dejó ciego al vigilante de dev. `workflow_dispatch` desde `main` funciona hoy sin depender de esa variable.

## Informe diario de costos

Todos los días a las **07:00 de Bogotá** llega a Slack cuánto costó el día anterior, con los cinco servicios que más pesaron y el resto resumido en una línea. **Los lunes** el mismo mensaje agrega el gasto de la semana que terminó, de lunes a domingo. Sale por el topic `vetsoftware-dev-finops`.

### Por qué el reloj es de AWS y no de GitHub

Corría por `cron` de GitHub Actions y **llegaba tarde todos los días**. Los eventos `schedule` de GitHub no están garantizados: se encolan en un pool compartido y se retrasan bajo carga. Medido en este repositorio, el drift —programado a las 11:17 UTC— disparó a las 13:54, 14:40, 17:24, 17:05, 17:23 y 17:30 en seis días seguidos. Entre dos y seis horas de desviación.

Ahora lo dispara **EventBridge Scheduler**, el mismo mecanismo del apagado programado, que sí cumple el horario. Y la lógica vive en una Lambda: mover solo el reloj habría exigido guardar en AWS un token de GitHub con permiso de escritura, es decir, una credencial de larga vida en un proyecto que montó todo el OIDC para no tener ninguna.

`modules/cost_report` contiene la función, su rol, el log group y el schedule.

### Cuatro cosas que conviene tener presentes

- **La cifra es de la cuenta AWS completa, no de un ambiente.** Cost Explorer factura por cuenta, así que mientras dev y prod compartan cuenta el total incluye a los dos. Por eso el mensaje nombra la cuenta consultada y no el ambiente. Cuando las cuentas se separen, basta instanciar el módulo en el root de prod.
- **La función solo lee.** Su rol tiene `ce:GetCostAndUsage`, publicar en el topic de finops y escribir sus propios logs. Nada más: no puede crear su log group, para que borrarlo se note en lugar de recrearse uno sin caducidad ni cifrado.
- **Cuesta dinero.** Cost Explorer cobra USD 0.01 por request: una consulta diaria son unos USD 0.30 al mes. Se hace **una sola consulta por corrida**, también los lunes: la ventana semanal ya contiene el día y la función lo recorta de ahí en vez de pedirlo aparte. La Lambda en sí cabe en el free tier.
- **Fechas y montos en UTC y costo sin combinar**, igual que la consola. Si Cost Explorer todavía no tiene datos del día anterior, el informe **no se envía**: publicar `USD 0.00` cuando lo que falta es el dato sería mentir. Queda la advertencia en el log de la función.

### Reenviar un día a mano

```bash
aws lambda invoke --function-name vetsoftware-dev-cost-report \
  --payload '{"as_of":"2026-08-09"}' --cli-binary-format raw-in-base64-out \
  respuesta.json
```

`as_of` es la fecha UTC de referencia: el informe cubre **el día anterior** a esa fecha. Sin payload, la referencia es hoy.

## Avisos del encendido y del apagado (solo dev)

Encender y apagar dev deja rastro en el mismo canal de Slack que ya escucha Amazon Q Developer, el que usa el aviso de despliegue. No hay webhook ni secreto nuevo: los tres mensajes viajan como *custom notification* al topic `vetsoftware-dev-alarms`.

| Aviso | Cuándo | Contenido |
|---|---|---|
| Ambiente encendido | Al terminar `Start dev environment` | Base disponible, servicio en una tarea, quién lo lanzó, enlace a la corrida y recordatorio del apagado programado. |
| Ambiente apagado a mano | Al terminar `Stop dev environment` | Servicio en cero tareas, base deteniéndose y cómo volver a encenderlo. |
| Apagado programado | A la hora en que EventBridge baja el servicio, 20:00 `America/Bogota` | Que el ambiente se está apagando, a qué hora cae la base y cómo volver a encenderlo. |

Cuando el encendido o el apagado manual fallan también sale un mensaje, con el motivo del fallo y el estado que tenía el ambiente antes de intentarlo. El aviso nunca decide el resultado del workflow: si no se puede publicar, queda como advertencia en el log y como línea en el Summary del run, y el workflow termina como habría terminado igual.

El aviso del apagado programado no lo emite ningún script sino un tercer horario de EventBridge Scheduler, `vetsoftware-dev-stop-notice`, que publica en el topic con el mismo rol y a la misma hora que el horario que baja el servicio. Se apaga junto con el resto cuando `scheduled_shutdown_enabled` es `false`, y no existe si el ambiente no tiene Slack configurado.

## GitHub Environments operativos

Cada bootstrap emite solamente los roles de su ambiente:

| Environment | Rama autorizada | Rol |
|---|---|---|
| `iac-plan-dev` | `develop` (solo manual, drift, costos y despliegue) | `dev.plan` |
| `iac-apply-dev` | `develop` | `dev.apply` |
| `iac-plan-prod` | `main` (idem) | `prod.plan` |
| `iac-apply-prod` | `main` | `prod.apply` |

### El plan de un PR corre sin Environment

Las deployment branch policies son la unica proteccion que permite el plan Free
(ver el limite en la nota de GitFlow), y solo saben casar nombres de rama. La
referencia de un pull request es `refs/pull/N/merge`, que no es una rama: con
`iac-plan-dev` atado a `develop`, el job moria en dos segundos con
`Branch "refs/pull/N/merge" is not allowed to deploy to iac-plan-dev`, antes de
ejecutar un solo paso. El plan no llegaba nunca al PR, que es justo para lo que
existe el workflow.

Por eso `terraform-plan-dev/prod` declara el Environment de forma condicional:

```yaml
environment: ${{ github.event_name != 'pull_request' && 'iac-plan-dev' || '' }}
```

La condicion va invertida a proposito. En las expresiones de GitHub la cadena
vacia es *falsy*, de modo que `== 'pull_request' && '' || 'iac-plan-dev'` cae
siempre en la ultima rama y el environment no se suelta nunca: el valor no vacio
tiene que ocupar el lado verdadero.

Un PR corre sin Environment y su token OIDC llega como `...:pull_request`, sujeto
que la trust policy del rol de **plan** acepta ademas del suyo propio. Los roles de
**apply** no lo aceptan: ahi vive la aprobacion manual y abrirlos a un PR la
eliminaria. `workflow_dispatch` conserva el Environment, porque su referencia si es
una rama.

La contrapartida es que un job sin Environment tampoco lee las variables del
Environment. Las que necesita el plan viven a nivel de repositorio y **van
prefijadas**, porque ese scope es plano y `dev` y `prod` usan los mismos nombres con
valores distintos: `DEV_AWS_ACCOUNT_ID`, `PROD_AWS_ACCOUNT_ID`, y asi con el resto.
Son una copia de las del Environment, que siguen sirviendo a drift, costos y
despliegue de imagen: **al cambiar un valor hay que actualizar los dos sitios**.

Nada en GitHub obliga a que las dos copias coincidan, y `GRAFANA_OTLP_ENDPOINT` ya
divergió una vez: el plan aprobaba un endpoint y el apply escribía otro, ademas de
producir deriva falsa. Por eso su valor canonico esta versionado en
`.github/telemetry-endpoints.json` y todo job que lo consuma ejecuta
`.github/scripts/assert-telemetry-endpoint.ps1` justo despues del checkout, antes de
configurar credenciales de AWS. El detalle, el valor correcto y el procedimiento para
cambiar de stack estan en [Endpoint OTLP de Grafana Cloud](TELEMETRIA_OTLP.md).

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

`TF_VARS_JSON` lleva las variables no sensibles del ambiente -alertas, presupuesto,
umbrales- y `deploy-backend-dev/prod` **tambien la consume**, no solo plan, apply y
drift. Si el despliegue de imagen no la ve, su plan diverge del real y pide destruir
lo que esas variables sostienen: el guard image-only lo rechaza por tocar recursos
fuera de ECS, sin que haya nada mal en la imagen. Debe estar en los cuatro
Environments del ambiente, plan y apply.

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

### El unico secret que va a nivel de repositorio: `TF_VAR_GRAFANA_LOGS_ACCESS_KEY`

El envio durable de logs viene encendido en dev (`log_shipping_enabled = true`) y la
validacion de `grafana_logs_access_key` —formato `<loki_instance_id>:<token>`— corre
**en tiempo de plan**, no de apply. Sin ese valor, el ciclo muere con
`Invalid value for variable` antes de leer nada de AWS: no es un fallo del apply que
se pueda dejar para despues, tumba el plan del pull request.

A diferencia de los tres anteriores, **este secret todavia vive en el scope de
repositorio**, y eso es una deuda abierta, no una decision. El razonamiento original
era correcto en su premisa —en un `pull_request` el job del plan corre sin Environment
y no puede leer los secrets de `iac-plan-dev`— pero sacaba la conclusion equivocada:
un secret de repositorio entra en el entorno de un job que dispara **cualquier**
`pull_request`, incluido el que propone anadir un paso `run:` que lo exfiltre. Sin
Environment no hay *deployment branch policy* que intervenga.

Desde el 19 de agosto de 2026 el camino de `pull_request` de `terraform-plan-dev`
recibe un **valor sintetico** con el formato correcto
(`000000:pull-request-placeholder`) en lugar de la credencial. El plan solo comprueba
el formato, y el valor real nunca entra en el state porque `modules/secrets` lo
escribe con `secret_string_wo` y version, asi que el plan del PR sigue siendo exacto.

Con eso, los cuatro jobs que necesitan el valor real —`terraform-apply-dev`,
`terraform-drift-dev` y las dos fases de `deploy-backend-dev`— corren **siempre** con
Environment, de modo que el secret **puede y debe** moverse a `iac-plan-dev` e
`iac-apply-dev` y borrarse del scope de repositorio. Los workflows no necesitan
ningun cambio para eso: la expresion lee igual un secret de repositorio que uno de
Environment. **Y hay que rotar la credencial en Grafana Cloud**, porque ha estado
expuesta a la superficie de `pull_request` todo el tiempo que llevo escrita asi.

No lleva prefijo `DEV_` porque prod no tiene envio durable de logs: no hay con que
chocar en un scope plano.

```powershell
gh secret set TF_VAR_GRAFANA_LOGS_ACCESS_KEY --repo kefaroTech/vetsoftware-infrastructure
```

**Debe existir antes de mergear el trabajo de log shipping.** El valor no es el token
a secas; su formato exacto, el instance ID de Loki y el scope de la Cloud Access
Policy estan en [Gestion de secretos](GESTION_DE_SECRETOS.md).

El gate local no detecta que falte, porque el ciclo local toma el valor de
`environments/dev/terraform.tfvars` en disco. El primer sitio donde se nota es el plan
del pull request.

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

## Trazabilidad de la cuenta y su coste

`modules/account_baseline` responde a quien hizo que en la cuenta. Va instanciado
en los dos roots de ambiente y no en el bootstrap, porque necesita la CMK y el
topic de alertas del entorno. Cada cuenta lleva el suyo: CloudTrail, GuardDuty y
Access Analyzer son singletons de cuenta, y dev y prod viven en cuentas
separadas.

Lo que queda activo **no genera cargo**:

| Control | Que responde | Coste |
|---|---|---|
| CloudTrail, primer trail, *management events* | Quien cambio que en la cuenta | Sin cargo |
| S3 server access logging | Quien descargo que documento | Sin cargo por evento |
| IAM Access Analyzer | Que recurso quedo accesible desde fuera | Sin cargo |

El unico gasto real es el almacenamiento en S3 de lo que se escribe: megabytes
al mes para esta cuenta. Los access logs caducan segun `access_log_retention_days`;
el rastro no caduca, porque su Object Lock es COMPLIANCE y cubre el termino de
firmeza fiscal de cinco anios.

Dos controles quedan **apagados a proposito, y el contrato de cada ambiente lo
fija**, de modo que encenderlos sea una decision y no una deriva:

- `enable_s3_data_events` — data events de CloudTrail sobre los buckets
  regulados. USD 0,10 por cada 100.000 eventos. Responde la misma pregunta que
  el access logging con mas detalle y en minutos en lugar de horas.
- `enable_guardduty` — es la unica pieza de **deteccion**: el resto del modulo
  registra, pero no avisa. Se factura por volumen analizado.

Con los dos apagados el hallazgo de trazabilidad queda cubierto y el de
deteccion de comportamiento anomalo sigue abierto. Es un intercambio explicito,
no un olvido.

### ECS Exec

Apagado en produccion (`enable_execute_command = false`). Una shell en el
contenedor lee `DB_PASSWORD`, `JWT_SECRET` y `DIAN_ENC_KEY`. Activarlo con un
apply enciende a la vez el registro de las sesiones en
`/ecs/<nombre>/exec`, cifrado con la CMK: CloudTrail anota que alguien invoco
`ExecuteCommand`, pero no lo que se tecleo dentro. Se apaga despues del
diagnostico.

## Log groups de RDS sin gestionar

RDS crea `/aws/rds/instance/<id>/<log>` la primera vez que exporta, y lo hace con
retencion *Never expire* y la clave gestionada por AWS. Desde que el modulo `database`
los declara, el plan los ve como *create* y CloudWatch responde
`ResourceAlreadyExistsException`: el apply no avanza hasta que pasen al state.

`terraform-cycle.ps1` los adopta solo, con el mismo criterio que usa para el servicio
ECS huerfano. Antes de planear lista los grupos bajo el prefijo de la instancia, se
queda con los que el modulo declara —`error`, `slowquery`, `audit`— y importa los que
falten del state. El import no toca los eventos ya almacenados; el apply posterior solo
les fija caducidad y CMK. Igual que con ECS, la adopcion ocurre unicamente en
`-Mode Apply`: plan y drift se limitan a reportarla en el step summary, porque nunca
mutan el state.

Un grupo `general` no entra en ese allowlist a proposito. El modulo ya no lo exporta y
fija `general_log = 0` en el parameter group, asi que no puede volver a llenarse, pero
adoptarlo solo para que Terraform lo destruya seria borrar registros de forma
desatendida. Si existe en algun ambiente, se revisa y se borra a mano:

```powershell
aws logs describe-log-groups --log-group-name-prefix "/aws/rds/instance/vetsoftware-dev-mysql/general"
aws logs delete-log-group --log-group-name "/aws/rds/instance/vetsoftware-dev-mysql/general"
```

Mientras el grupo siga existiendo se factura su almacenamiento aunque ya no reciba
eventos.

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
