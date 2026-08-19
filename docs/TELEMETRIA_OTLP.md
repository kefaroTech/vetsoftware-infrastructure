# Endpoint OTLP de Grafana Cloud: dónde vive, cuál es y cómo verificarlo

El backend exporta trazas y métricas por OTLP a Grafana Cloud. El endpoint no es un
secreto, pero **sí es específico del stack**, y este repositorio ya lo tuvo tres veces
distinto a la vez entre el plan, el apply y la documentación. Este documento fija el
valor, explica por qué existen varias copias y describe el control automático que
impide que vuelvan a separarse.

## El valor correcto

| Ambiente | Endpoint OTLP | Stack | Clúster | Verificado |
|---|---|---|---|---|
| `dev` | `https://otlp-gateway-prod-us-east-3.grafana.net/otlp` | `vastcoyote3439` | `prod-us-east-3` | 2026-08-18 |
| `prod` | — no hay stack productivo — | — | — | 2026-08-18 |

`us-east-3` es el clúster real del stack. **`us-east-0` no existe**: es el valor
equivocado que estuvo circulando y el que hay que reconocer de un vistazo en cualquier
revisión.

La barra final es irrelevante. Los dos roots normalizan antes de usarlo
—`trimsuffix(var.grafana_otlp_endpoint, "/")`, en `environments/dev/locals.tf` y en
`environments/prod/main.tf`— de modo que `.../otlp` y `.../otlp/` son el mismo valor
para Terraform. El verificador normaliza igual, porque un guardarraíl que es más
estricto que el código que protege solo genera falsos rojos.

## Por qué hay más de una copia del mismo valor

Esta es la parte que hace falta entender antes de tocar nada.

**`Terraform plan dev` corre en `pull_request` sin GitHub Environment, a propósito.**
La deployment branch policy de `iac-plan-dev` está atada a `develop`, y la referencia
de un pull request es `refs/pull/N/merge`, que no es una rama: nunca casa, y el job
moría antes de ejecutar un solo paso. El razonamiento completo está en
[Automatización del ciclo Terraform](TERRAFORM_AUTOMATION.md), sección *El plan de un
PR corre sin Environment*.

La contrapartida es que un job sin Environment **no puede leer las variables del
Environment**. Por eso el plan lee variables de **repositorio con prefijo**, y todo lo
demás lee las del **Environment sin prefijo**:

| Quién | Scope | Nombre de la variable |
|---|---|---|
| `terraform-plan-dev` (pull request) | repositorio | `DEV_GRAFANA_OTLP_ENDPOINT` |
| `terraform-plan-dev` (`workflow_dispatch`) | environment `iac-plan-dev` | `GRAFANA_OTLP_ENDPOINT` |
| `terraform-drift-dev` | environment `iac-plan-dev` | `GRAFANA_OTLP_ENDPOINT` |
| `terraform-apply-dev` | environment `iac-apply-dev` | `GRAFANA_OTLP_ENDPOINT` |
| `deploy-backend-dev` (job `plan`) | environment `iac-plan-dev` | `GRAFANA_OTLP_ENDPOINT` |
| `deploy-backend-dev` (job `apply`) | environment `iac-apply-dev` | `GRAFANA_OTLP_ENDPOINT` |
| ciclo local | disco | `environments/dev/terraform.tfvars` |

Son orígenes **independientes**: cambiar uno no cambia los otros, y nada en GitHub
obliga a que coincidan.

### Qué pasó cuando divergieron

El plan leía `us-east-0` y el apply `us-east-3`. Dos consecuencias, y la segunda es
peor que la primera:

1. **Lo aprobado en el pull request no era lo que se aplicaba.** El plan que un humano
   revisaba y aprobaba describía una task definition con un endpoint, y el apply creaba
   otra. La revisión seguía existiendo, pero había dejado de revisar el cambio real.
2. **El workflow de drift reportaba deriva que no existía.** Comparaba con el valor
   equivocado y señalaba un recurso cambiado por consola que nadie había tocado. Una
   deriva falsa es cara: consume el mismo análisis que una real y erosiona la confianza
   en las que sí lo son.

Ninguna de las dos produce un fallo rojo. Ese es exactamente el motivo de que haga
falta un control explícito.

## El guardarraíl

### El valor canónico está versionado

`.github/telemetry-endpoints.json` guarda el endpoint canónico por ambiente, con el
stack, el clúster, la fecha de verificación y la lista de sitios donde vive una copia.
El mismo manifiesto lleva también los valores canónicos del ruler de Mimir
(`ruler_url` y `metrics_tenant_id`), con su propio verificador y su propio flujo de
sincronización de reglas de alerta: ver [Alertas en Grafana Cloud](ALERTAS_GRAFANA_CLOUD.md).

Es un archivo del repositorio, así que **se revisa en el pull request**. Las variables
de GitHub no: cambiarlas no deja rastro en el diff, no pasa por revisión y solo se
descubre leyendo la interfaz o preguntando a la API. Poner el valor de referencia bajo
control de versiones es lo que convierte un cambio de endpoint en algo discutible antes
de que ocurra.

### El verificador

`.github/scripts/assert-telemetry-endpoint.ps1` compara el valor efectivo del job
—`TF_VAR_grafana_otlp_endpoint`, que es exactamente lo que va a leer Terraform— contra
el canónico del manifiesto.

- **No coincide** → anotación de error y `exit 1`. El job muere antes de configurar
  credenciales de AWS, así que no llega a tocar el state ni a producir un plan.
- **Llega vacío** → `exit 1`. Un valor ausente indica una variable sin configurar en
  el scope que usa ese job, que es un modo de fallo tan real como el valor equivocado.
- **Ambiente sin canónico** (hoy `prod`) → anotación de *warning* y `exit 0`.
- **Coincide salvo la barra final** → pasa. Se normaliza con `TrimEnd("/")`, igual que
  hace `trimsuffix` en los roots.

El paso corre **después del checkout y antes de configurar credenciales AWS** en los
nueve jobs que consumen la variable: plan, apply, drift y las dos fases de
`deploy-backend` en dev, y sus equivalentes en prod. Y el manifiesto y el script están
en el filtro `paths:` de los workflows de plan, de modo que modificarlos dispara la
propia verificación.

### Por qué prod solo avisa

No existe stack productivo de Grafana Cloud ni variables `PROD_*` configuradas.
Bloquear el ciclo de prod por una decisión que todavía no se ha tomado convertiría el
control en un estorbo, así que el manifiesto declara `"otlp_endpoint": null` y el
script avisa sin fallar.

Cuando se cree el stack productivo hay que hacer dos cosas a la vez: fijar el endpoint
en el manifiesto —con lo que el check pasa a ser bloqueante en prod sin tocar ningún
workflow— y corregir `environments/prod/terraform.tfvars.example:9`, que conserva un
`us-east-0` de marcador.

## Cómo verificarlo a mano

Contra GitHub, que es la fuente que de verdad usan los workflows:

```powershell
gh variable list --repo kefaroTech/vetsoftware-infrastructure | Select-String OTLP
gh variable list --repo kefaroTech/vetsoftware-infrastructure --env iac-plan-dev  | Select-String OTLP
gh variable list --repo kefaroTech/vetsoftware-infrastructure --env iac-apply-dev | Select-String OTLP
```

Las tres deben devolver el mismo valor que la tabla de arriba.

El propio verificador se puede ejecutar en local sobre un valor cualquiera:

```powershell
./.github/scripts/assert-telemetry-endpoint.ps1 -Environment dev -Endpoint "https://otlp-gateway-prod-us-east-3.grafana.net/otlp"
$LASTEXITCODE   # 0
```

## Al cambiar de stack

El orden importa, porque hay un momento en que las copias están desincronizadas:

1. Actualizar `.github/telemetry-endpoints.json` en la rama de trabajo, con la nueva
   fecha de verificación. El plan del pull request fallará: eso es correcto, está
   señalando que las variables todavía no se han movido.
2. Actualizar **las tres** variables de GitHub: la de repositorio con prefijo y las de
   los dos Environments.
3. Actualizar `environments/dev/terraform.tfvars.example` y este documento.
4. Relanzar el plan. Al quedar en verde, las cuatro copias son la misma.

Cambiar solo las variables y no el manifiesto también deja el plan en rojo, que es el
comportamiento buscado: el valor canónico es el del repositorio, no el de la consola.

## Lo que este control no cubre

El endpoint de ingesta de **logs** por Kinesis Firehose es otro valor y otro camino:
vive en `grafana_logs_firehose_endpoint`, con un `default` en
`environments/dev/variables.tf` y validación propia, así que ya es único y versionado
por construcción. Su credencial está en
[Gestión de secretos](GESTION_DE_SECRETOS.md).
