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

Se inyecta entero como JSON por `TF_VAR_grafana_secrets_json`; la versión es `grafana_secret_version`.

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

#### En GitHub va como secret de repositorio, no de Environment

El secret se llama **`TF_VAR_GRAFANA_LOGS_ACCESS_KEY`** y es el único que no vive en un GitHub Environment. La razón es la misma que obliga a prefijar las variables del plan: en un `pull_request`, `Terraform plan dev` corre **sin Environment** —la deployment branch policy nunca casa con `refs/pull/N/merge`— y por tanto no puede leer los secrets de `iac-plan-dev`. Un secret de repositorio sí lo ven los cinco jobs de dev que ejecutan Terraform: `terraform-plan-dev`, `terraform-apply-dev`, `terraform-drift-dev` y las dos fases de `deploy-backend-dev`, porque un job con Environment hereda además los del repositorio. No lleva prefijo `DEV_` porque prod no tiene envío durable de logs y no hay con qué chocar.

Y hace falta en **todos** ellos, no solo en el apply: `log_shipping_enabled` viene en `true` y la validación de formato se evalúa en tiempo de plan, así que sin el secret el plan del pull request muere con `Invalid value for variable` antes de tocar AWS. El gate local no lo detecta porque toma el valor del `terraform.tfvars` del disco.

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
