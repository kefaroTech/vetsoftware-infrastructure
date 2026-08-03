# Cloudflare Pages para los frontends

Terraform no administra los fronts: ambos son SPAs estáticas publicadas en Cloudflare Pages. Este documento fija el contrato entre esa capa y la infraestructura AWS que sí administra Terraform.

## Ambiente dev

Cuenta `Software@kefaro.tech's Account` (`9ee92528fcfa07b620f517a6173eca6b`), zona `kefaro.tech`.

| Repositorio | Proyecto Pages | Dominio | Respaldo |
|---|---|---|---|
| `VetSoftwareFront` (admin) | `vetsoftware-front-dev` | `dev-admin.kefaro.tech` | `vetsoftware-front-dev.pages.dev` |
| `VetSoftwarePublicFront` | `vetsoftware-public-front-dev` | `dev-public.kefaro.tech` | `vetsoftware-public-front-dev.pages.dev` |

Ambos proyectos son *direct upload* con `production_branch = develop`: no hay integración de Git en Cloudflare. Cada repositorio publica desde `.github/workflows/deploy-dev.yml` con `wrangler pages deploy dist` al hacer push a `develop`.

Los registros DNS son CNAME proxied hacia el subdominio `pages.dev` de cada proyecto. Ambos dominios personalizados están validados y en estado `active`, pero sirven 404 hasta que exista el primer despliegue del proyecto.

## Contrato con la infraestructura AWS

Los hostnames de arriba deben coincidir exactamente con las variables del root `environments/dev`:

```hcl
cors_allowed_origins          = ["https://dev-public.kefaro.tech", "https://dev-admin.kefaro.tech"]
registration_verification_url = "https://dev-public.kefaro.tech/verify-email"
password_reset_url            = "https://dev-public.kefaro.tech/restablecer-contrasena"
login_url                     = "https://dev-public.kefaro.tech/login"
api_domain_name               = "dev-api.kefaro.tech"
```

Un cambio de dominio en Pages obliga a reaplicar `environments/dev`: `CORS_ALLOWED_ORIGINS` y las URLs de correo se inyectan como variables de entorno de la tarea ECS.

Los fronts apuntan a la API por `VITE_API_URL` en su archivo `.env.dev`; ese valor debe ser el mismo `api_domain_name` publicado por el túnel.

## Credenciales de publicación

Cada repositorio de front necesita, en su GitHub Environment `development`:

| Nombre | Tipo | Valor |
|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | secret | `9ee92528fcfa07b620f517a6173eca6b` |
| `CLOUDFLARE_API_TOKEN` | secret | Token de API con `Cloudflare Pages: Edit` sobre esa cuenta |
| `VITE_RECAPTCHA_SITE_KEY` | variable | Solo `VetSoftwarePublicFront`; site key pública del dominio dev |

El token debe ser distinto del que se use para producción y limitarse a la cuenta. No existe ningún secreto de runtime en Pages: las variables `VITE_*` se resuelven durante el build en el runner de GitHub y quedan incrustadas en el JavaScript entregado al navegador.

## Producción

Producción todavía no tiene proyectos Pages creados; los fronts productivos se publican en `app.vetsoftware.co` y `admin.vetsoftware.co`, dominios que no pertenecen a la zona `kefaro.tech`. Al crearlos debe replicarse esta misma estructura con proyectos y tokens separados por entorno.
