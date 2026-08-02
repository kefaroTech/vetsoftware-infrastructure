# Gestión de secretos

Terraform no debe recibir secretos mediante archivos versionados. Los valores sensibles se inyectan desde GitHub Environments, AWS Secrets Manager/SSM o archivos locales ignorados.

- `*.tfvars`, `backend.hcl`, estados, planes, claves privadas y almacenes de credenciales están ignorados.
- Solo se versionan plantillas `*.tfvars.example` y `backend.hcl.example`, siempre con marcadores no funcionales.
- El hook versionado ejecuta Gitleaks sobre el contenido staged. Después de clonar, instálelo con `git config core.hooksPath .githooks`.
- El workflow `Secret history scan` revisa el historial en cada push y pull request.
- Configure `Secret history scan` como required check y habilite Secret scanning/Push protection en GitHub.
- Los tokens `vetsoftware-prod` y `vetsoftware-dev` de Cloudflare Tunnel son distintos. Guárdelos como secret del GitHub Environment correspondiente e inyéctelos mediante `TF_VAR_cloudflare_tunnel_token`.
- La rotación exige aumentar `cloudflare_tunnel_token_version`, aplicar Terraform, comprobar las nuevas conexiones ECS y solo entonces revocar el token anterior.
