# Gate de calidad Terraform

El repositorio aplica una politica fail-closed antes de cada commit y en GitHub Actions. El mismo ejecutor valida local y CI para impedir diferencias de comportamiento.

## Controles obligatorios

El modo `full`, usado por `.githooks/pre-commit`, ejecuta en este orden:

1. `git diff --cached --check` y bloqueo de state, planes, variables reales, backends locales, credenciales, secretos y llaves privadas.
2. Rechazo de cambios IaC relevantes sin preparar para que el snapshot validado sea exactamente el que se confirma.
3. Rechazo de archivos, argumentos o comentarios que desactiven controles de seguridad.
4. Gitleaks sobre el contenido preparado.
5. Versiones exactas Terraform `1.15.8` y TFLint `0.64.0`.
6. `terraform fmt -check -diff -recursive`.
7. TFLint con severidad minima `notice` en bootstrap, dev, prod y el modulo de roles OIDC.
8. `terraform init -backend=false -input=false -lockfile=readonly` y `terraform validate -json`; cualquier error o advertencia bloquea.
9. `terraform test` en prod, dev y `modules/github_iac_roles`.
10. Trivy `0.71.2`, fijado por digest, para incidencias `MEDIUM`, `HIGH` y `CRITICAL`.

El hook no ejecuta `terraform plan`, `apply`, state remoto ni operaciones que requieran credenciales AWS.

## Politica de cero tolerancia

- El resultado permitido del escaneo IaC es cero incidencias en todas las severidades bloqueantes configuradas.
- No se admiten baselines, archivos de omision, politicas de omision, comentarios inline ni fechas de caducidad para ocultar un hallazgo.
- Un hallazgo se corrige en el recurso, se elimina el recurso inseguro o se rediseña la arquitectura.
- Cambiar el gate, la imagen fijada del escaner o su rango de severidades requiere la misma revision humana que cualquier cambio de seguridad.

La arquitectura actual materializa esta politica con ALB interno y HTTPS obligatorio, Cloudflare Tunnel saliente, CIDR externos explicitamente autorizados, endpoints privados para APIs AWS, CMK con rotacion, VPC Flow Logs y RDS con backup, proteccion contra borrado, snapshot final e IAM DB Auth habilitado.

Desarrollo conserva `db.t4g.micro` por decision de costo. El contrato automatizado impide cambiarlo accidentalmente y CloudWatch alerta cuando `FreeableMemory` cae por debajo de 256 MiB.

## Ejecucion y logs

```powershell
# Gate completo; requiere que todos los cambios IaC esten preparados
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
