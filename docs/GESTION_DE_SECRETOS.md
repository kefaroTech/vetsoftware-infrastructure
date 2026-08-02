# Gestión de secretos

Terraform no debe recibir secretos mediante archivos versionados. Los valores sensibles se inyectan desde GitHub Environments, AWS Secrets Manager/SSM o archivos locales ignorados.

- `*.tfvars`, `backend.hcl`, estados, planes, claves privadas y almacenes de credenciales están ignorados.
- Solo se versionan plantillas `*.tfvars.example` y `backend.hcl.example`, siempre con marcadores no funcionales.
- El hook versionado ejecuta Gitleaks sobre el contenido staged. Después de clonar, instálelo con `git config core.hooksPath .githooks`.
- El workflow `Secret history scan` revisa el historial en cada push y pull request.
- Configure `Secret history scan` como required check y habilite Secret scanning/Push protection en GitHub.
