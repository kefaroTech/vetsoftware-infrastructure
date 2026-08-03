# Cloudflare Tunnel para el backend

La API no publica un balanceador ni abre puertos de entrada en AWS. Cada tarea ECS ejecuta Spring Boot y un sidecar `cloudflared` dentro del mismo espacio de red `awsvpc`; el conector alcanza el backend mediante `http://localhost:8080` y abre únicamente conexiones salientes hacia Cloudflare.

AWS documenta que los contenedores de una misma tarea `awsvpc` pueden comunicarse por `localhost`: <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-networking-awsvpc.html>. Cloudflare admite explícitamente hostnames publicados hacia servicios locales como `http://localhost:8080`: <https://developers.cloudflare.com/tunnel/>.

## Prerrequisitos

1. Mantener la zona `kefaro.tech` activa en Cloudflare.
2. Crear dos túneles remotos independientes: `vetsoftware-prod` y `vetsoftware-dev`.
3. Conservar un token diferente por entorno y no guardarlo en Git ni en archivos `tfvars`.
4. Mantener libres los hostnames `api.kefaro.tech` y `dev-api.kefaro.tech`; Cloudflare administra sus registros al publicar cada ruta.

## Crear y autenticar los túneles

En **Cloudflare Dashboard > Networking > Tunnels**:

1. Crear `vetsoftware-prod` y copiar solo su token.
2. Crear `vetsoftware-dev` y copiar su token independiente.
3. Inyectar el token correspondiente antes de planificar o aplicar:

```powershell
$env:TF_VAR_cloudflare_tunnel_token = "TOKEN_DEL_ENTORNO"
```

Para CI/CD, guardar cada valor como secret del GitHub Environment que corresponda. La rotación se materializa aumentando `cloudflare_tunnel_token_version`.

## Configurar los hostnames publicados

En el túnel `vetsoftware-prod`, crear la ruta:

- Hostname: `api.kefaro.tech`
- Service type: `HTTP`
- URL: `localhost:8080`
- HTTP Host Header: sin override
- TLS hacia origen: no aplica; el salto ocurre por loopback dentro de la tarea

En `vetsoftware-dev`, crear la misma ruta con hostname `dev-api.kefaro.tech` y URL `localhost:8080`.

### Estado actual de desarrollo

El túnel de desarrollo ya está aprovisionado en la cuenta `Software@kefaro.tech's Account`:

| Elemento | Valor |
|---|---|
| Túnel | `vetsoftware-dev`, `config_src = cloudflare` (administrado remotamente) |
| Tunnel ID | `6c11d95b-917c-4a5e-ac24-8c620cfb6d60` |
| Ingress | `dev-api.kefaro.tech` → `http://localhost:8080`; catch-all `http_status:404` |
| DNS | `dev-api.kefaro.tech` CNAME proxied → `6c11d95b-917c-4a5e-ac24-8c620cfb6d60.cfargotunnel.com` |

El token del conector no se guarda en este repositorio. Obtenerlo desde **Zero Trust > Networks > Tunnels > vetsoftware-dev** o con la API:

```powershell
# Requiere un token de API con permiso Cloudflare Tunnel: Read
$env:TF_VAR_cloudflare_tunnel_token = (
  curl.exe -s -H "Authorization: Bearer $env:CF_API_TOKEN" `
    "https://api.cloudflare.com/client/v4/accounts/9ee92528fcfa07b620f517a6173eca6b/cfd_tunnel/6c11d95b-917c-4a5e-ac24-8c620cfb6d60/token" |
  ConvertFrom-Json).result
```

El túnel permanece sin conexiones hasta que la tarea ECS de dev arranque su sidecar `cloudflared` con ese token.

Los dos roots Terraform exponen el contrato que debe coincidir con Cloudflare:

```powershell
terraform -chdir=environments/prod output cloudflare_tunnel_origin_url
terraform -chdir=environments/dev output cloudflare_tunnel_origin_url
```

Ambos outputs deben devolver `http://localhost:8080`. El HTTPS público termina en Cloudflare; el transporte entre Cloudflare Edge y `cloudflared` permanece cifrado por el túnel.

## Migración segura desde el ALB

Si el ALB ya existe, no aplicar la eliminación de forma desordenada:

1. Cambiar primero ambos hostnames de Cloudflare a `http://localhost:8080` y verificar los health endpoints. Las tareas existentes ya contienen ambos contenedores, por lo que pueden atender por loopback antes de eliminar el ALB.
2. Si producción tiene deletion protection activa, deshabilitarla explícitamente con el rol anterior o una sesión administrativa antes del plan destructivo.
3. Aplicar `environments/dev` para retirar su listener rule, target group y reglas cruzadas del security group compartido.
4. Aplicar `environments/prod` para retirar el ALB, su target group, listener, logs y security group.
5. Aplicar `bootstrap` al final para retirar de los roles OIDC los permisos ACM, ELB y CloudWatch Log Delivery que solo eran necesarios durante la migración.

Revisar cada plan: dev no debe destruir la VPC compartida y prod no debe destruir ECS, RDS, Valkey, Alloy, buckets ni secretos.

## Verificación operativa

1. Confirmar tareas ECS estables y health checks de contenedor sanos.
2. Revisar `/ecs/<entorno>-backend/cloudflare-tunnel`; debe registrar conexiones activas sin errores repetitivos.
3. Probar `https://api.kefaro.tech/api/v1/actuator/health/readiness` y su equivalente de desarrollo.
4. Confirmar que el security group del backend no tiene reglas de entrada.
5. Confirmar que solo mantiene las salidas necesarias: TCP/7844 hacia Cloudflare, TCP/443 público y conexiones privadas a RDS, Valkey y telemetría.
6. Verificar la alarma `cloudflare-tunnel-errors`; los logs JSON con nivel `error` alimentan su métrica de CloudWatch.

Cada tarea adicional crea otra réplica del conector con el mismo token. Cloudflare mantiene conexiones redundantes por túnel y admite múltiples réplicas: <https://developers.cloudflare.com/tunnel/>.

Si rota un token, aumente su contador de versión, aplique Terraform y fuerce un nuevo deployment de ECS. Revoque el token anterior únicamente después de comprobar las nuevas conexiones.
