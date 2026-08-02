# Cloudflare Tunnel para el backend

La API no expone el ALB a Internet. Cada tarea ECS ejecuta un sidecar `cloudflared` fijado por digest; el sidecar abre conexiones salientes HTTP/2 hacia Cloudflare y reenvia las solicitudes al ALB HTTPS interno.

## Prerrequisitos

1. La zona `kefaro.tech` debe estar activa en Cloudflare.
2. Solicitar en ACM, en `us-east-1`, un certificado que incluya `api.kefaro.tech` y `dev-api.kefaro.tech`.
3. Crear en Cloudflare los CNAME de validacion entregados por ACM y esperar el estado `Issued`.
4. Usar el ARN emitido como `certificate_arn` de produccion.
5. Mantener una lista de CIDR reales para Resend, reCAPTCHA, Grafana Cloud y cualquier otra dependencia HTTPS. Terraform prohibe la ruta universal.

## Crear los tuneles

En **Cloudflare Dashboard > Networking > Tunnels**:

1. Crear un tunel remoto llamado `vetsoftware-prod`.
2. Copiar solo el token del comando de instalacion; no guardar el comando ni el token en Git.
3. Crear otro tunel remoto llamado `vetsoftware-dev` y conservar su token por separado.
4. Inyectar cada token unicamente en su entorno:

```powershell
$env:TF_VAR_cloudflare_tunnel_token = "TOKEN_DEL_ENTORNO"
```

Para CI/CD, guardar el mismo valor como secret del GitHub Environment correspondiente. La version del secreto se rota aumentando `cloudflare_tunnel_token_version`.

## Configurar produccion

Aplicar primero `environments/prod` y consultar:

```powershell
terraform -chdir=environments/prod output cloudflare_tunnel_origin_url
```

En el tunel `vetsoftware-prod`, crear una ruta de aplicacion publicada:

- Hostname: `api.kefaro.tech`
- Service: `HTTPS`
- URL: el DNS interno del output, puerto `443`
- Origin Server Name: `api.kefaro.tech`
- HTTP Host Header: `api.kefaro.tech`
- TLS verification: habilitada

No habilitar `noTLSVerify`. Cloudflare crea el registro DNS del hostname al guardar la ruta; no debe existir otro registro con el mismo nombre.

## Configurar desarrollo

Aplicar despues `environments/dev` y consultar:

```powershell
terraform -chdir=environments/dev output cloudflare_tunnel_origin_url
```

En `vetsoftware-dev`, crear la ruta:

- Hostname: `dev-api.kefaro.tech`
- Service: `HTTPS`
- URL: el origen privado del output, puerto `443`
- Origin Server Name: `dev-api.kefaro.tech`
- HTTP Host Header: `dev-api.kefaro.tech`
- TLS verification: habilitada

El `HTTP Host Header` es obligatorio porque el ALB compartido selecciona el target group de desarrollo mediante host routing.

## Verificacion operativa

1. Confirmar tareas estables y targets saludables en ECS y el ALB.
2. Revisar el grupo `/ecs/<entorno>-backend/cloudflare-tunnel`; debe registrar cuatro conexiones activas sin errores repetitivos.
3. Probar `https://api.kefaro.tech/api/v1/actuator/health/readiness` y su equivalente dev.
4. Confirmar logs de acceso del ALB en `/aws/vendedlogs/elasticloadbalancing/<entorno>/access`.
5. Verificar que el security group no tiene reglas de entrada por CIDR y que solo permite salida TCP/7844 a los rangos Cloudflare declarados.

Si rota un token, aumente su contador de version, aplique Terraform y fuerce un nuevo deployment de ECS. El token anterior debe revocarse solo despues de verificar las nuevas conexiones.
