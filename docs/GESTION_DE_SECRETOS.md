# Gestión de secretos

Terraform no debe recibir secretos mediante archivos versionados. Los valores sensibles se inyectan desde GitHub Environments, AWS Secrets Manager/SSM o archivos locales ignorados.

- `*.tfvars`, `backend.hcl`, estados, planes, claves privadas y almacenes de credenciales están ignorados.
- Solo se versionan plantillas `*.tfvars.example` y `backend.hcl.example`, siempre con marcadores no funcionales.
- El hook versionado ejecuta Gitleaks sobre el contenido staged. Después de clonar, instálelo con `git config core.hooksPath .githooks`.
- El workflow `Secret history scan` revisa el historial en cada push y pull request.
- Configure `Secret history scan` como required check y habilite Secret scanning/Push protection en GitHub.
- Los tokens `vetsoftware-prod` y `vetsoftware-dev` de Cloudflare Tunnel son distintos. Guárdelos como secret del GitHub Environment correspondiente e inyéctelos mediante `TF_VAR_cloudflare_tunnel_token`.
- La rotación exige aumentar `cloudflare_tunnel_token_version`, aplicar Terraform, comprobar las nuevas conexiones ECS y solo entonces revocar el token anterior.

## Los dos secretos de Grafana Cloud en dev

Ambos son *write-only* (`secret_string_wo` en `modules/secrets/main.tf`): Terraform los escribe pero nunca los lee, y su contenido no queda en el state. Cada uno se reescribe solo cuando sube su propia variable de versión.

### `vetsoftware-dev/grafana-cloud` — telemetría de la aplicación

Ya no se inyecta como un JSON entero. Cada clave llega por su propia variable —`TF_VAR_otlp_username`, `TF_VAR_otlp_api_key` y `TF_VAR_otel_exporter_otlp_headers`— y el JSON lo compone `modules/secrets/main.tf` con `jsonencode`, igual que el secreto de logs de más abajo. La versión sigue siendo `grafana_secret_version`.

Los nombres de clave de la tabla son **contrato**: las definiciones de tarea de ECS los leen por sufijo (`"<arn>:OTEL_EXPORTER_OTLP_HEADERS::"`), así que renombrar uno no rompe ningún plan —rompe el arranque del contenedor—. Por eso los fija el módulo y no quien rellena el secret de GitHub.

| Clave | Quién la consume | Para qué |
|---|---|---|
| `OTEL_EXPORTER_OTLP_HEADERS` | el backend, como variable de entorno | exportación OTLP directa |
| `OTLP_USERNAME`, `OTLP_API_KEY` | el sidecar colector, por `basicauth` | trazas y métricas con cola en disco |

### `vetsoftware-dev/grafana-cloud-logs` — envío durable de logs

Secreto **dedicado**, con una sola clave dentro. Lo lee Kinesis Firehose por su cuenta en cada entrega, mediante `secrets_manager_configuration`: la clave no se declara en el `.tf`, no viaja en ninguna variable con valor por defecto y no entra en el state —que es exactamente lo que sí pasaría usando el argumento `access_key` del stream, porque es un atributo normal y Terraform ni siquiera admite asignarle un valor `ephemeral`—.

```json
{ "api_key": "1706326:glc_..." }
```

**El valor no es el token.** La plantilla oficial de CloudFormation de Grafana Labs lo compone como `${LogsInstanceID}:${LogsWriteToken}`, y su snippet oficial de Terraform hace lo mismo con `format("%s:%s", ...)`. Para este stack el instance ID de Loki es **`1706326`**, así que el valor correcto lleva ese prefijo y los dos puntos **sin espacios alrededor**. Pegar solo el `glc_...` —que es lo que devuelve la consola al crear la Cloud Access Policy, y por tanto lo que uno tiene en el portapapeles— produce un apply verde, un stream creado y **cero entregas**, sin excepción ni alarma de infraestructura: solo Loki vacío por esa ruta. El plan lo detiene antes, con la validación `^[0-9]+:.+` sobre `grafana_logs_access_key`.

El token es de una **Cloud Access Policy con el único scope `logs:write`**, distinto del que usa OTLP. Se inyecta por `TF_VAR_grafana_logs_access_key` y se rota subiendo `grafana_logs_secret_version`.

#### En GitHub sigue siendo secret de repositorio, y eso hay que corregirlo

El secret se llama **`TF_VAR_GRAFANA_LOGS_ACCESS_KEY`** y es el único que no vive en un GitHub Environment. No lleva prefijo `DEV_` porque prod no tiene envío durable de logs y no hay con qué chocar.

La razón que se escribió en su día era correcta a medias: en un `pull_request`, `Terraform plan dev` corre **sin Environment** —la deployment branch policy nunca casa con `refs/pull/N/merge`— y por tanto no puede leer los secrets de `iac-plan-dev`. Pero la conclusión que se sacó fue la equivocada. Un secret de repositorio entra en el entorno de un job que dispara **cualquier** `pull_request` contra `develop`, incluidas las de colaboradores con permiso de escritura, y basta con que esa misma PR añada un paso `run:` para sacarlo fuera. Sin Environment, no hay *deployment branch policy* que intervenga en ningún momento. Era el único punto del proyecto donde una credencial viva cruzaba a la superficie de `pull_request`.

Desde el 19 de agosto de 2026 el camino de `pull_request` recibe un **valor sintético** con el formato correcto, `000000:pull-request-placeholder` (`.github/workflows/terraform-plan-dev.yml`). El plan de la PR sigue siendo exacto: la validación sólo comprueba el formato `^[0-9]+:.+$`, y el valor real nunca entra en el state porque `modules/secrets` lo escribe con `secret_string_wo` más `secret_string_wo_version`, así que un valor distinto tampoco produce diff.

Hace falta en todos los jobs de dev que planifican, no sólo en el apply: `log_shipping_enabled` viene en `true` y la validación de formato se evalúa en tiempo de plan, así que sin **algún** valor el plan del pull request muere con `Invalid value for variable` antes de tocar AWS. El gate local no lo detecta porque toma el valor del `terraform.tfvars` del disco.

Quedan dos pasos, los dos fuera del repositorio:

1. **Mover el secret** a los environments `iac-plan-dev` e `iac-apply-dev` y borrarlo del scope de repositorio. Los cuatro jobs que necesitan el valor real —`terraform-apply-dev`, `terraform-drift-dev` y las dos fases de `deploy-backend-dev`— corren siempre con Environment, así que ninguno se rompe, y los workflows no necesitan ningún cambio: la expresión lee igual un secret de repositorio que uno de Environment.
2. **Rotar la credencial en Grafana Cloud.** Estuvo expuesta a la superficie de `pull_request` todo el tiempo que llevó escrita así.

```powershell
gh secret set TF_VAR_GRAFANA_LOGS_ACCESS_KEY --repo kefaroTech/vetsoftware-infrastructure
```

**Créelo antes de mergear.** El mapeo en los workflows ya está puesto; lo único que falta es el valor.

### Por qué dos secretos y no una clave más en el primero

Tres razones, en orden de peso:

1. AWS **no documenta** si Firehose tolera claves hermanas dentro del secreto: solo dice que fallará al conectar si el JSON no tiene el formato correcto. Ese fallo es silencioso y ocurre en tiempo de entrega, que es la clase de fallo que este trabajo existe para eliminar. Un secreto con una sola clave no deja margen a la duda.
2. Los secretos de GitHub son de **solo escritura**: no se pueden leer para editarlos. Añadir una clave al JSON compartido obligaba a reescribir a ciegas unas credenciales OTLP que ya funcionan, y a subir `grafana_secret_version` para que el cambio surtiera efecto. Con un secreto propio, el que funciona no se toca.
3. Separa los ciclos de rotación: rotar el token de logs no obliga a reescribir las credenciales de trazas y métricas.

Cuesta USD 0,40 al mes, que es la línea más cara de todo el envío de logs. Está declarado en `docs/COSTS.md`.

### Cifrado

Los secretos de dev usan la clave gestionada `aws/secretsmanager`, **no** la CMK del proyecto (`describe-secret` devuelve `KmsKeyId: null`). Por eso el rol de Firehose necesita `secretsmanager:GetSecretValue` pero **no** `kms:Decrypt` para leerlo, y `modules/kms` no cambia. Mantenga esa convención al añadir secretos nuevos: cambiarla obliga a repartir permisos de KMS que hoy nadie necesita.
