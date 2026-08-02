# Gate de calidad Terraform

El repositorio aplica una politica fail-closed antes de cada commit y en GitHub Actions. El mismo ejecutor comparte los controles, pero adapta el alcance: pre-commit valida el snapshot preparado y sus dependencias directas; CI valida el repositorio completo.

## Controles obligatorios

El modo `full`, usado por `.githooks/pre-commit`, ejecuta en este orden:

1. `git diff --cached --check` y bloqueo de state, planes, variables reales, backends locales, credenciales, secretos y llaves privadas.
2. Rechazo de cambios IaC relevantes sin preparar para que el snapshot validado sea exactamente el que se confirma.
3. Rechazo de archivos, argumentos o comentarios que desactiven controles de seguridad.
4. Gitleaks sobre el contenido preparado.
5. Calculo del alcance desde `git diff --cached`: archivos Terraform preparados, raices consumidoras y contratos afectados.
6. Versiones exactas Terraform `1.15.8` y TFLint `0.64.0` cuando existen cambios IaC afectados.
7. `terraform fmt -check -diff` unicamente sobre archivos Terraform preparados.
8. TFLint, `terraform init -backend=false -input=false -lockfile=readonly` y `terraform validate -json` solo en las raices afectadas; cualquier error o advertencia bloquea.
9. `terraform test` solo para las raices afectadas que poseen contratos.
10. Trivy `0.71.2`, fijado por digest, para incidencias `MEDIUM`, `HIGH` y `CRITICAL` en las raices afectadas.

Los modulos compartidos usan un mapa de impacto explicito. Por ejemplo, un cambio en `modules/database` valida `environments/dev` y `environments/prod`; un cambio en `modules/ecr` valida `bootstrap`. Un modulo nuevo sin mapa bloquea el commit hasta declarar sus consumidores. Los cambios al propio gate, a TFLint, a la version de Terraform o al workflow fuerzan una comprobacion completa porque pueden afectar a todas las raices.

El modo `ci` conserva formato recursivo, lint, validaciones, contratos y Trivy sobre todo el repositorio. Esta validacion global es el check obligatorio para impedir que la optimizacion local o un hook omitido introduzcan deuda.

El hook no ejecuta `terraform plan`, `apply`, state remoto ni operaciones que requieran credenciales AWS.

## Politica fail-closed con excepcion arquitectonica controlada

- El resultado permitido del escaneo IaC es cero incidencias no autorizadas en todas las severidades bloqueantes configuradas.
- No se admiten baselines, archivos de omision, politicas globales, skip flags ni comentarios inline distintos de los tres marcadores controlados de `AWS-0104`.
- `AWS-0104` se permite exclusivamente en backend prod, Alloy prod y backend dev para TCP/443 hacia APIs publicas de AWS y SaaS. El gate valida ruta, regla y nombre exactos antes de ejecutar Trivy.
- Un hallazgo se corrige en el recurso, se elimina el recurso inseguro o se rediseña la arquitectura.
- Cambiar el gate, la imagen fijada del escaner o su rango de severidades requiere la misma revision humana que cualquier cambio de seguridad.

La arquitectura actual materializa esta politica con ALB interno y HTTPS obligatorio, Cloudflare Tunnel saliente restringido, HTTPS publico solo en puerto 443, S3 Gateway Endpoint, CMK con rotacion, VPC Flow Logs y RDS con backup, proteccion contra borrado, snapshot final e IAM DB Auth habilitado.

Desarrollo conserva `db.t4g.micro` por decision de costo. El contrato automatizado impide cambiarlo accidentalmente y CloudWatch alerta cuando `FreeableMemory` cae por debajo de 256 MiB.

## Ejecucion y logs

```powershell
# Gate pre-commit incremental; requiere que todos los cambios IaC esten preparados
./scripts/quality/terraform-gate.ps1 -Mode full

# Solo formato, lint, validate y tests
./scripts/quality/terraform-gate.ps1 -Mode terraform

# Politica de seguridad y Trivy IaC
./scripts/quality/terraform-gate.ps1 -Mode security
```

Cada ejecucion muestra el progreso y tiempos en consola. Tambien conserva el transcript en `.tools/logs/terraform-gate/` y actualiza `latest-<modo>.log`. `.tools/` esta ignorado por Git.

IntelliJ importa las tres configuraciones compartidas de `.run/`. Para verlas de forma permanente en Services:

1. Abrir **View > Tool Windows > Services** (`Alt+8`).
2. Elegir **Add Service > Run Configuration Type**.
3. Seleccionar **PowerShell**.
4. Ejecutar `IaC - Full pre-commit gate`, `IaC - Terraform quality` o `IaC - Security scan`.

La salida aparece en vivo en Services/Run. Si no aparece el tipo PowerShell, habilitar el plugin PowerShell incluido en IntelliJ y comprobar la ruta del ejecutable en Settings.
