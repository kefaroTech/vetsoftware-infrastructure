# Alertamiento operativo — alertas de Grafana Cloud

Runbook de las **26 alertas Grafana-managed** definidas en `observability/grafana-managed/`.
Cada regla enlaza aquí desde su anotación `runbook`, y el ancla es el nombre de la regla en
minúsculas: la sección `### VetSoftwareSloFastBurn` responde a `#vetsoftwareslofastburn`.
**Si renombras una regla, renombra su encabezado o rompes el enlace.**

No confundir con [`ALERTAS_OPERATIVAS.md`](ALERTAS_OPERATIVAS.md), que cubre **el otro plano
de alertas**: las alarmas de CloudWatch que llegan por SNS y AWS Chatbot y vigilan ECS, RDS,
Valkey y el envío de logs por Firehose. Son dos sistemas independientes sobre la misma
infraestructura. Varias secciones de aquí derivan allí cuando la respuesta está en el lado de
AWS; conviene tener los dos a mano.

## Antes de seguir un procedimiento

- **Los nombres de métrica llevan sufijo `_milliseconds_`, no `_seconds_`.** El backend
  exporta por OTLP push y Micrometer emite en milisegundos. Una consulta con `_seconds_`
  devuelve vacío y parece que no hay problema.
- **La métrica `up` no existe.** La genera Prometheus al hacer scrape y aquí la ingesta es
  push. Para saber si el backend vive, mira la edad del último dato de una métrica real.
- **No hay avisos de resuelto en Slack.** El canal solo cuenta lo que empieza. Para saber si
  algo sigue abierto: Alerting → Alert rules.
- Etiqueta `job` = `mainvet/vetsoftware`. `instance` = `ecs-fargate-spot` para **todas** las
  tareas: lo que distingue dos despliegues es `service_version`.

## Estado del plano de alertas

Al escribir este runbook se midió cada alerta contra la señal real. **Siete reglas no hacían
lo que su nombre promete. Las siete están corregidas** — pero corregido no es lo mismo que
vigente, y la diferencia está explicada justo debajo de la tabla. Las corregidas se mantienen
aquí con su historia porque saber qué medía antes una alerta es lo que permite interpretar un
panel de hace tres semanas. Una alerta rota que aparenta cobertura es más peligrosa que una
ausente, y por eso la que todavía no mide va primero.

| Regla | Qué le pasa |
| --- | --- |
| `VetSoftwareValkeyLatencyHigh` | ~~**No puede disparar.** `lettuce_milliseconds_bucket` solo publica `le="+Inf"`, así que `histogram_quantile` devuelve `NaN` siempre~~ → **CORREGIDO 2026-08-19, en dos mitades**: (a) bordes explícitos `slo: lettuce: 1ms,5ms,25ms,50ms,100ms` en el `application.yml` del backend —cinco bordes SLO y **no** `percentiles-histogram`, con la cuenta de series delante— y (b) exclusión de las operaciones de protocolo (`CLIENT`/`HELLO`/…) de la expresión, que mezclaban dos poblaciones de latencia. **Es la única de las siete que no basta con sincronizar: los bordes solo aparecen al desplegar una imagen del backend.** Ver la sección de la alerta |
| `VetSoftwareProcessCpuHigh` | ~~**No puede disparar.** El gauge tiene techo ≈ 0,50 (cuota de 0,5 vCPU normalizada sobre `system_cpu_count = 1`) y el umbral era 0,85~~ → **CORREGIDO 2026-08-19**: la expresión divide por la cuota real (`512 / 1024`), así que 0,85 significa «85 % de la cuota». Ver la sección de la alerta |
| `VetSoftwareHttp5xxRateHigh` | ~~**Muda en dev.** Guarda ≥ 20 req/5 min sobre una línea base de 10, de la cual el 98,5 % era la sonda de salud~~ → **CORREGIDO 2026-08-19**: `/actuator/**` fuera del numerador y del denominador, y agrupado por entorno. **Sigue muda en dev, ahora por la razón correcta**: dev recibe ~11 peticiones de usuario **al día** y con eso no existe una tasa de error. La calibración es la de prod |
| `VetSoftwareHttpP95LatencyHigh` | ~~Misma guarda, mismo silencio~~ → **CORREGIDO 2026-08-19** igual que la anterior. Guarda ≥ 20 = 1/(1−0,95), el mínimo para que el p95 no sea el máximo del lote |
| `VetSoftwareHttpP99LatencyCritical` | ~~Igual. Además, un p99 sobre 20 muestras es la petición más lenta, no un percentil~~ → **CORREGIDO 2026-08-19**: misma exclusión, y la guarda **sube** a ≥ 100 = 1/(1−0,99) precisamente por eso |
| `VetSoftwareSecurityTokenTableGrowth` | ~~**Se rompe en cada despliegue.** Con dos `service_version` vivas, `group_left()` falla por serie duplicada~~ → **CORREGIDO 2026-08-19**: el join va por `(job, instance, service_version)` y el lado derecho se agrega con `max by (...)`, así que no puede volver a duplicarse. `execErrState: Error` **se mantiene** deliberadamente, con la descripción corregida para que un estado de Error no se lea como crecimiento de tokens |
| `VetSoftwareScheduledJobFailing` (critical) | ~~**Falso positivo estructural.** `security.tokens.cleanup` solo emite `no_work` y nunca `success`, así que un fallo aislado cumplía «ningún éxito en 2 h» al instante~~ → **CORREGIDO 2026-08-19** con una guarda de repetición `>= 2`. **Ojo: NO se arregla metiendo `no_work` en el lado excluido** —se probó y deja muda la alerta de la reconciliación DIAN, que alterna `no_work` con `failure`. Ver la sección de la alerta |

Y un punto ciego que no es una regla rota sino una que no puede ver su fallo más probable:
**`VetSoftwareEmailSendFailing`** no dispara si falta `RESEND_API_KEY`, porque
`ResendEmailClient.ready()` emite `misconfigured` y nunca llega a `dispatch`: no se registra
ni un `failure`.

### Corregido no es vigente: dónde está cada mitad

Esta tabla describe **los ficheros del repositorio**. Lo que evalúa Grafana Cloud ahora mismo se
consulta en Alerting → Alert rules, y hasta que el cambio se publique puede ser la versión
anterior. Hay dos caminos distintos, con dueños y tiempos distintos:

- **Las seis correcciones de expresión** viven en `observability/grafana-managed/`. Se publican
  cuando la rama llega a `develop` y corre `sync-alert-rules-dev` (o `-prod`). No necesitan nada
  del backend: en cuanto el workflow pasa, la regla nueva evalúa.
- **Los bordes del histograma de `lettuce`** son un cambio del repositorio del **backend**
  (`VetSoftware/src/main/resources/application.yml`, clave
  `management.metrics.distribution.slo`), y no llegan a la señal hasta que se construye y
  despliega una imagen que los lleve. **A 2026-08-19 ese cambio no está en `develop` del
  backend.** La comprobación cuesta un segundo y no hace falta abrir ninguna consola:

  ```promql
  count by (le) (count_over_time(lettuce_milliseconds_bucket{job="mainvet/vetsoftware"}[24h]))
  ```

  Verificado el 2026-08-19: devuelve **solo `le="+Inf"`**. Cuando devuelva
  `1, 5, 25, 50, 100, +Inf`, los bordes están desplegados y `VetSoftwareValkeyLatencyHigh` mide
  de verdad; mientras devuelva un único borde, la alerta sigue sin poder dispararse por muy
  corregida que esté su expresión. La ventana de 24 h es deliberada: con el apagado nocturno de
  dev, una consulta instantánea devuelve vacío y se confunde «no hay bordes» con «no hay backend».

## Cómo está organizado

Cada sección responde siempre a lo mismo, en este orden: **qué significa**, **qué la
dispara**, **primero mirar**, **causas habituales**, **qué hacer**, **cuándo no es un
incidente** y, si aplica, **defectos conocidos de la señal** — este último recoge lo que la
auditoría de telemetría del backend encontró sobre la señal que alimenta esa alerta, para no
perseguir fantasmas.

---

## 1. Objetivos de servicio (SLO)

### VetSoftwareSloFastBurn

**Qué significa** — Un objetivo de servicio se está gastando su margen de fallo de 30 días
tan rápido que, si sigue así, lo agota en poco más de dos días. Es una emergencia en curso,
no un resumen del mes: algo está fallando ahora mismo.

**Qué la dispara** — Sobre las series ya calculadas por el ruler de Mimir (datasource
`grafanacloud-prom`):

```promql
vetsoftware:slo_burn_rate:ratio_rate1h
and
vetsoftware:slo_burn_rate:ratio_rate5m > 14.4
and
(vetsoftware:sli_total_events:rate1h * 3600) >= 20
```

con umbral `> 14.4` sobre la ventana de 1 hora. Las tres piezas:

- **14.4×** = gastar en una hora el 2 % del presupuesto de 30 días. A ese ritmo el mes se
  consume en ~50 horas.
- **La ventana corta (`rate5m`)** tiene que superar el mismo múltiplo. Sin ella, la alerta
  seguiría sonando durante una hora después de que el problema se arreglara.
- **La guarda de volumen** exige ≥ 20 eventos en la última hora. Con 3 peticiones a la hora,
  un solo fallo da un burn rate de 100 y no significa nada.

El burn rate no se mide sobre la métrica cruda: la cadena es `sli_{bad,total}_events:rate5m`
→ `avg_over_time` por ventana → `sli_bad:ratio_rateXX` →
`slo_burn_rate:ratio_rateXX = ratio / (1 - objetivo)`. Todo eso lo graban las 57 recording
rules del ruler cada minuto; la alerta solo compara.

**`for: 2m`** — dos evaluaciones consecutivas (el grupo evalúa cada 1 m). Es corto a
propósito: el antirrebote real ya lo da la doble ventana, y esta alerta es `critical`. Con
`group_wait: 30s` de la ruta crítica, desde que empieza el daño hasta que llega a Slack pasan
~2,5–3 minutos.

**Primero mirar**

1. **Qué SLO y con qué ritmo.** El mensaje de Slack agrupa por `(alertname, severity)`: si dos
   SLOs arden a la vez, llega **una sola** notificación. La lista completa está en
   Alerting → Alert rules de `https://vastcoyote3439.grafana.net`, o aquí:
   ```promql
   vetsoftware:slo_burn_rate:ratio_rate1h > 14.4
   ```
2. **¿El backend sigue emitiendo?** `up` **no existe** en este stack (la ingesta es push OTLP,
   no scrape). La edad del último dato:
   ```promql
   time() - max(max_over_time(timestamp(jvm_memory_used_bytes{job="mainvet/vetsoftware"})[24h:1m]))
   ```
   Por encima de ~300 s el backend no está emitiendo. En dev eso es casi siempre el apagado
   programado de EventBridge (20:00/20:15 Bogotá, L-V y fines de semana completos).
3. **Numerador y denominador, en eventos por hora, no en ratios.**
   ```promql
   vetsoftware:sli_bad_events:rate1h * 3600
   vetsoftware:sli_total_events:rate1h * 3600
   ```
   Un burn rate de 100 sobre 21 eventos y sobre 5.000 son dos incidentes distintos.
4. **Si el SLO es `api-availability`, `api-latency`, `auth-login`, `pos-checkout` o
   `clinical-write`** (todos son HTTP), quién devuelve 5xx:
   ```promql
   topk(10, sum by (uri, status) (rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",status=~"5.."}[15m])))
   ```
   Ojo con el nombre: **`_milliseconds_`, nunca `_seconds_`** — Micrometer exporta en
   milisegundos por OTLP y una consulta con `_seconds_` devuelve vacío sin avisar.
   Si el SLI es de latencia, el umbral es un borde `le` **entero** (`le="1000"` para
   `api-latency`, `le="2000"` para POS y clínico):
   ```promql
   sum(rate(http_server_requests_milliseconds_bucket{job="mainvet/vetsoftware",status!~"5..",le="1000"}[15m]))
   / sum(rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",status!~"5.."}[15m]))
   ```
5. **Si el SLO es `dian-transmission`**, el desglose por resultado — es una métrica de negocio,
   no HTTP:
   ```promql
   sum by (result) (rate(vetsoftware_business_dian_transmissions_total{job="mainvet/vetsoftware"}[15m]))
   ```
   `rejected`, `contingency` y `error` gastan presupuesto; `pending` ni siquiera entra en el
   denominador. Lee antes el apartado «Defectos conocidos»: `rejected` miente.
6. **Los logs del intervalo.** En Loki las etiquetas reales de dev son `service_name` /
   `namespace` / `environment`:
   ```logql
   {service_name="vetsoftware"} | json | level="ERROR"
   ```
   Acota la ventana al intervalo en que subió el burn rate, no a «última hora» por defecto.
7. **Si el SLO es `inventory-movement`**, mira
   `vetsoftware_business_inventory_movements_total{result="error"}`. Si la métrica no existe, no
   es que no haya errores: es que no hay tráfico de inventario en dev todavía.

**Causas habituales**

1. **Fallo determinista de un proveedor externo** — token, credencial o configuración rota.
   Falla el 100 % de las operaciones y el burn rate se va a 100 de golpe. Es el caso vivo hoy
   con `dian-transmission`.
2. **Despliegue reciente.** Correlaciona con `service_version`; la etiqueta está en métricas y
   trazas (no en logs, ver TEL-37).
3. **Saturación de dependencia**: pool de Hikari agotado, RDS al límite, Valkey lento. Para RDS
   y ECS manda el lado AWS (`docs/ALERTAS_OPERATIVAS.md` §2 y §3), no este runbook.
4. **Latencia por encima del borde** sin ningún 5xx: la disponibilidad está verde y arde el SLI
   de latencia. Se distingue mirando qué `sli` (`availability` vs `latency`) trae la instancia.

**Qué hacer**

*Mitigación inmediata*
- Si hubo despliegue en la ventana, revertir es más rápido que diagnosticar.
- Si es un fallo determinista de proveedor (401/403 de MATIAS, dominio no verificado en
  Resend), arreglar la credencial o la configuración: no hay reintento que lo salve.
- Si vas a convivir con el incidente, **silencio con vencimiento** en Alerting → Silences.
  Nunca estirar `repeat_interval`: eso degrada el canal para todos los `critical` futuros.

*Arreglo de fondo*
- Un `critical` sin acción posible es un defecto del alertamiento, no del sistema. Si esta
  alerta suena y la respuesta es «no se puede hacer nada ahora», el SLO o su umbral están mal
  elegidos y hay que discutirlo, no silenciarlo cada vez.

**Cuándo NO es un incidente**

- **Ventana residual tras el arreglo.** `ratio_rate1h` conserva memoria de hasta una hora.
  Verificado el 2026-08-19: con el backend sin emitir desde hacía ~17 minutos,
  `slo_burn_rate:ratio_rate1h` seguía devolviendo valor. Si `ratio_rate5m` ya bajó de 14,4 la
  alerta se resuelve sola; no hay aviso de resuelto, hay que mirar la UI.
- **Ráfaga en dev con poco tráfico.** Dev mueve ~370 peticiones a la semana. La guarda de 20
  eventos/hora se cumple solo en ráfagas, y en una ráfaga corta un puñado de fallos basta.
  Comprueba siempre el paso 3 antes de escalar.
- **No lo descartes por costumbre en `dian-transmission`**: el burn rate ~100 medido el
  2026-08-19 sobre 301 transmisiones en 24 h es un incidente **real** (documento atascado con
  fallo determinista), no ruido de dev.

**Defectos conocidos de la señal**

- **TEL-05 — `result="rejected"` de DIAN mezcla tres poblaciones.**
  `MatiasInvoiceProvider.java:204-211` convierte **cualquier** 4xx del proveedor en
  `rejected(...)` terminal: el 422 (rechazo real de validación, aislado), el 401/403 (token o
  configuración rota → falla el 100 % de las emisiones) y el 429 (rate limit transitorio) llegan
  indistinguibles a `vetsoftware_business_dian_transmissions_total`. **Si esta alerta suena por
  `dian-transmission`, no asumas «datos del cliente mal»**: comprueba primero la credencial de
  MATIAS. El emisor de la métrica es
  `VetSoftware/src/main/java/com/vetsoftware/app/electronicdocument/application/usecase/TransmissionResultPersister.java`
  (`persist` → `recordOutcome`).
- **TEL-28 — no hay salto métrica → traza.** Los exemplars llegan, pero el datasource cloud
  espera `traceID` y el backend emite `trace_id`. El p99 alto **no** te da una traza de ejemplo
  con un clic; hay que buscar la traza a mano por tiempo y ruta. Requiere ticket a Soporte de
  Grafana Cloud (lo ejecuta el dueño de la cuenta).
- **TEL-03 — `level=warn` está dominado por 4xx.** ~35 handlers de `GlobalExceptionHandler`
  registran 404/409/400 en WARN. Al ir a Loki, filtra por `level="ERROR"`; buscar en WARN te
  entierra bajo «Resource not found».
- **TEL-37 — los logs de dev no llevan `service_version`.** «¿Empezó con el último despliegue?»
  no se responde filtrando en Loki: hay que triangular por hora contra las métricas, que sí lo
  llevan.
- **TEL-04 — el filtro de cardinalidad descarta métricas sin dejar rastro.**
  `BusinessMetricCardinalityFilter.java:97-100` tira el meter completo, sin contador ni log,
  cuando aparece un valor fuera de la allowlist. Si el denominador de un SLI de negocio cae de
  golpe sin causa aparente, sospecha de esto antes que de una caída de tráfico.

---

### VetSoftwareSloSlowBurn

**Qué significa** — El mismo objetivo se está degradando de forma **sostenida**: no es un pico
de cinco minutos, lleva horas mal. Al ritmo actual el margen de fallo de 30 días se agota en
unos cinco días.

**Qué la dispara**

```promql
vetsoftware:slo_burn_rate:ratio_rate6h
and
vetsoftware:slo_burn_rate:ratio_rate30m > 6
and
(vetsoftware:sli_total_events:rate6h * 21600) >= 60
```

con umbral `> 6` sobre la ventana de 6 horas. **6×** = gastar el 5 % del presupuesto en seis
horas. La ventana corta aquí es de 30 minutos (no 5) porque una degradación de seis horas no se
apaga en cinco minutos, y la guarda pide ≥ 60 eventos en las últimas 6 horas.

**`for: 15m`** — la ventana de 6 h se mueve despacio; 15 minutos evitan que un bache de tráfico
bajo (una hora con cuatro peticiones, dos de ellas malas) dispare un aviso. Es `warning`, y la
ruta de warning añade `group_wait: 5m`: unos ~20 minutos hasta Slack, con recordatorio
**diario**, no cada 4 h.

**Primero mirar**

1. **Distinguir «sigue mal» de «estuvo mal».** Compara la ventana larga con la corta:
   ```promql
   vetsoftware:slo_burn_rate:ratio_rate6h
   vetsoftware:slo_burn_rate:ratio_rate30m
   ```
   Si `rate30m` está por debajo de 6 y `rate6h` por encima, la causa ya pasó y la ventana se
   está vaciando. Si las dos están altas, sigue ocurriendo.
2. **¿Hay un FastBurn del mismo SLO?** En este stack **no hay reglas de inhibición** — la
   notification policy provisionada solo enruta por `severity` — así que ambas alertas llegan.
   Si FastBurn también está activa, atiende esa: es el mismo incidente visto con más urgencia.
3. **La forma de la curva de las últimas 12 horas** dice si es un escalón (despliegue, cambio de
   configuración) o una rampa (fuga, crecimiento de datos, degradación de dependencia). Consulta
   de rango sobre `vetsoftware:slo_burn_rate:ratio_rate30m`, paso 5 m.
4. **Volumen real de la ventana**, para no perseguir un fantasma estadístico:
   ```promql
   vetsoftware:sli_total_events:rate6h * 21600
   vetsoftware:sli_bad_events:rate6h * 21600
   ```
5. A partir de aquí, los pasos 4–7 de `VetSoftwareSloFastBurn` valen igual: desglose por
   `uri`/`status`, por `result` en DIAN, y logs `level="ERROR"` acotados a la ventana.

**Causas habituales**

1. **Degradación parcial**: una ruta concreta que falla siempre, o un porcentaje fijo de
   peticiones. Es el patrón clásico de esta alerta.
2. **Latencia que cruzó el borde**: el p99 pasó de 900 a 1.100 ms y el SLI de latencia empezó a
   contar todo lo que excede `le="1000"`. Nada «falla»; el SLO se degrada igual.
3. **Un incidente ya resuelto** cuya ventana de 6 h todavía no se vació.
4. **Dependencia externa lenta pero viva** — reintentos que triunfan al tercer intento suben la
   latencia sin producir un solo 5xx.

**Qué hacer**

*Mitigación inmediata*
- Si `rate30m` sigue alto, trátalo como el FastBurn: revertir el despliegue sospechoso o cortar
  la causa externa.
- Si solo `rate6h` está alto, no hagas nada operativo: anota la hora de inicio y espera a que la
  ventana se vacíe. Actuar aquí es actuar sobre el pasado.

*Arreglo de fondo*
- Una degradación sostenida que se repite semana tras semana no se arregla con mitigación: es
  capacidad o es una consulta que empeoró con el volumen de datos. Abre trabajo planificado con
  el burn rate como criterio de cierre, no la sensación de que «va mejor».

**Cuándo NO es un incidente**

- **Cola de seis horas tras el arreglo.** Con la causa corregida, esta alerta puede seguir activa
  hasta seis horas. Es la ventana funcionando. Verifícalo con el paso 1 y, si vas a convivir con
  ella, silencio **con vencimiento**.
- **Dev apagado.** Tras el corte de las 20:00 las series de ventana larga siguen vivas con los
  datos del día; una SlowBurn que aparece de madrugada sin backend encendido describe la tarde
  anterior.

**Defectos conocidos de la señal**

- **TEL-05** — igual que en FastBurn: si el SLO es `dian-transmission`, `result="rejected"` no
  distingue un rechazo fiscal legítimo de una credencial caducada. Revisa la credencial antes que
  los datos del documento.
- **TEL-11 no aplica aquí, y conviene saberlo.** La regla de inhibición que aplastaba
  `critical → warning` entre SLOs distintos vive en el `alertmanager.yml` del **stack Docker
  local**. El Alertmanager de Grafana Cloud usado en dev/prod no tiene esa regla, así que aquí un
  FastBurn **no** silencia el SlowBurn de otro SLO. Lo que sí ocurre es la **agrupación**: todas
  las instancias de este `alertname` se compactan en una notificación.
- **TEL-28** — sin exemplars, del p99 alto no se salta a una traza de ejemplo.
- **TEL-04** — un valor nuevo fuera de la allowlist hace desaparecer el meter sin contador, lo
  que se ve como una caída de denominador y no como un error.

---

### VetSoftwareSloTicketBurn

**Qué significa** — El objetivo se está degradando despacio pero de forma continua: a este ritmo
el margen del mes se agota en unos diez días. **No requiere respuesta inmediata.** Es trabajo
planificado; si llega de madrugada, no te levantes.

**Qué la dispara**

```promql
vetsoftware:slo_burn_rate:ratio_rate1d
and
vetsoftware:slo_burn_rate:ratio_rate2h > 3
and
(vetsoftware:sli_total_events:rate1d * 86400) >= 200
```

con umbral `> 3` sobre la ventana de un día. **3×** = agotar el presupuesto en ~10 días. La
ventana corta es de 2 horas y la guarda pide ≥ 200 eventos en 24 h — la más exigente de las
tres, porque un día entero con poco tráfico da ratios engañosos.

**`for: 1h`** — una ventana de 24 horas no cambia de opinión en diez minutos. Una hora elimina
cualquier oscilación de evaluación y, siendo `warning` con `group_wait: 5m`, la notificación
llega ~65 minutos después del cruce. Es intencional: esta alerta abre un ticket, no interrumpe.

**Primero mirar**

1. **Cuánto presupuesto queda de verdad** — es el dato que decide la prioridad:
   ```promql
   vetsoftware:slo_error_budget_remaining:ratio30d
   ```
   Con el presupuesto por encima del 50 % esto es trabajo de la próxima iteración. Por debajo del
   25 % ya deberías tener también `VetSoftwareSloErrorBudgetLow` activa.
2. **¿Es crónico o es el rastro de un incidente puntual?** Consulta de rango de 7 días sobre
   `vetsoftware:slo_burn_rate:ratio_rate1d` con paso 1 h. Un escalón que arranca en una fecha
   concreta es un incidente que envejece; una meseta plana es deuda estructural.
3. **Qué día se quemó el presupuesto** — rango de 30 días, paso 1 h:
   ```promql
   vetsoftware:sli_bad_events:rate1d * 86400
   ```
4. **Reparto por causa**, con el desglose que corresponda al SLI (`uri`/`status` para los HTTP,
   `result` para DIAN e inventario). Pasos 4–7 de `VetSoftwareSloFastBurn`.

**Causas habituales**

1. **Una ruta minoritaria que falla siempre** y que nadie ha priorizado porque no rompe nada
   visible.
2. **Latencia rozando el borde**: un porcentaje estable de peticiones por encima de `le="1000"` /
   `le="2000"`.
3. **Objetivo demasiado ambicioso para la realidad del servicio.** Si el burn rate lleva semanas
   en 3–4 sin ningún fallo identificable, el número del SLO es el que hay que revisar — cambiarlo
   es una decisión de producto, se discute y se documenta, no se ajusta en silencio para que la
   alerta calle.
4. **Rastro de un incidente resuelto**: la ventana de 24 h tarda un día completo en soltarlo.

**Qué hacer**

*Mitigación inmediata* — ninguna. Esa es la respuesta correcta y por eso la alerta existe con
este umbral. Si alguien quiere actuar de madrugada, la señal que lo justifica es FastBurn.

*Arreglo de fondo*
- Abrir ticket con el SLO, el SLI, el burn rate de 1 día y el presupuesto restante en la
  descripción. Criterio de cierre: `ratio_rate1d` por debajo de 1 de forma sostenida.
- Si la causa es el objetivo y no el servicio, la salida es revisar el objetivo en
  `observability/mimir-rules/vetsoftware-slo-rules.yml` (bloque 1, `slo_objective:ratio`) con la
  razón escrita.

**Cuándo NO es un incidente**

- **Casi siempre.** Por diseño esta alerta nunca es un incidente: es un aviso de tendencia.
- **Cola de 24 horas.** Tras resolver un incidente, sigue activa hasta un día entero. Se comprueba
  mirando `ratio_rate2h`: si está por debajo de 3, ya no está pasando.
- **En dev apenas debería sonar**: la guarda de 200 eventos/día solo la cumplen hoy
  `api-availability`, `api-latency` y `dian-transmission`. Si suena para otro SLO, mira primero si
  el volumen es real.

**Defectos conocidos de la señal**

- **Esta alerta no tiene prueba de promtool.** `VetSoftware/docker/tests/prometheus-slo.test.yml`
  cubre FastBurn, SlowBurn, ErrorBudgetExhausted y SeriesAbsent; **TicketBurn y ErrorBudgetLow no
  aparecen** (verificado por grep sobre el fichero; es el hallazgo TEL-30, «solo 12 de 37 alertas
  tienen prueba»). Una regresión en esta expresión pasaría el gate sin ruido. Y las pruebas que sí
  existen validan la **edición local** (nombres `_seconds_`): no cubren estos gemelos cloud.
- **TEL-05** — la misma trampa de `result="rejected"` en DIAN.
- **TEL-04** — descartes del filtro de cardinalidad sin contador.

---

### VetSoftwareSloErrorBudgetLow

**Qué significa** — A ese objetivo le queda menos de la cuarta parte de su margen de fallo del
mes. No es que algo esté fallando ahora: es que ya no hay colchón para el próximo incidente. Por
política de gobierno, los cambios no críticos de ese dominio piden revisión explícita hasta que el
presupuesto se recupere.

**Qué la dispara**

```promql
vetsoftware:slo_error_budget_remaining:ratio30d >= 0
```

con umbral `< 0.25`. La serie sale de:

```
sli_bad:ratio_rate30d   = bad_events:rate30d / total_events:rate30d
error_budget_remaining  = 1 - ( sli_bad:ratio_rate30d / (1 - objetivo) )
```

acotada entre −1 y 1: **1 = presupuesto intacto, 0 = agotado, negativo = SLO incumplido**. El
filtro `>= 0` delimita el reparto con `ErrorBudgetExhausted`, que cubre el tramo negativo; con
presupuesto exactamente 0 dispara esta y no aquella.

**`for: 30m`** — el número se mueve en la escala de días, no de minutos. Media hora solo evita
oscilaciones de evaluación. Es `warning`: llega a Slack ~35 minutos después, con recordatorio
diario.

**Primero mirar**

1. **Cuánto queda y de qué SLO:**
   ```promql
   vetsoftware:slo_error_budget_remaining:ratio30d
   vetsoftware:slo_compliance:ratio30d
   ```
2. **Cuándo se gastó.** Consulta de rango de 30 días, paso 1 h, sobre
   `vetsoftware:slo_error_budget_remaining:ratio30d`. Una caída vertical es un incidente fechado;
   un descenso continuo es degradación crónica.
3. **Qué días lo quemaron:**
   ```promql
   vetsoftware:sli_bad_events:rate1d * 86400
   ```
   en rango de 30 días. Cruza las fechas con despliegues e incidentes conocidos.
4. **¿Sigue gastándose ahora?**
   ```promql
   vetsoftware:slo_burn_rate:ratio_rate1h
   ```
   Por encima de 1 el presupuesto sigue bajando; por debajo, se está recuperando sola a medida que
   la ventana de 30 días suelta los días malos.

**Causas habituales**

1. **Un incidente reciente y concreto** que se comió el margen de un tirón. Lo normal.
2. **Degradación crónica de bajo nivel** — la que TicketBurn viene avisando desde hace días.
3. **Ventana de 30 días incompleta** (ver «Cuándo NO es un incidente»): con pocos días de
   historia, un día malo pesa como si fuera el mes entero.
4. **Objetivo mal calibrado**: 99,9 % en `auth-login` con el volumen real de dev significa que un
   puñado de 5xx agota el mes.

**Qué hacer**

*Mitigación inmediata* — ninguna sobre el número: describe daño ya ocurrido. Lo accionable es la
**política**: congelar cambios no críticos del dominio y priorizar fiabilidad hasta que se
recupere.

*Arreglo de fondo*
- Identificar el incidente que lo consumió y cerrar su causa raíz (los pasos 2 y 3 te dan la
  fecha).
- Si el presupuesto se agota mes tras mes sin ningún incidente identificable, el objetivo no
  refleja la realidad del servicio: revísalo con su razón escrita.

**Cuándo NO es un incidente**

- **Ventana de 30 días todavía sin llenar.** `sli_*_events:rate30d` es `avg_over_time(rate1d[30d])`:
  promedia **las muestras que existen**, no 30 días. Las reglas cloud se sincronizaron en agosto de
  2026, así que hasta mediados de septiembre el presupuesto se calcula sobre una ventana parcial y
  **sobrerreacciona**: un día malo puede vaciarlo entero. Contrástalo con el paso 3 antes de
  tratarlo como incumplimiento del mes.
- **Recuperación en curso.** Si el burn rate de 1 h está por debajo de 1, el presupuesto está
  subiendo solo. La alerta se apagará sin que nadie haga nada — y **no habrá aviso de resuelto**:
  los avisos de resolución están desactivados, el estado se consulta en Alerting → Alert rules.

**Defectos conocidos de la señal**

- **La serie del presupuesto NO EXISTE cuando un SLI de disponibilidad nunca ha tenido un evento
  malo** — y eso significa «perfecto», no «roto». Verificado en vivo el 2026-08-19:
  `slo_error_budget_remaining:ratio30d` devuelve `api-latency = 1` y
  `dian-transmission (availability) = -1`, pero **`api-availability` no aparece en absoluto**,
  teniendo tráfico. El motivo es estructural: los SLI de disponibilidad calculan `bad` con un
  `sum(rate(...))` filtrado por `status=~"5.."`, que **no produce serie** si no hay ni un 5xx, y la
  división posterior descarta la serie entera; los de latencia usan `clamp_min(A - B, 0)`, que sí
  materializa un 0. Consecuencia práctica: **un panel de presupuesto en «No data» puede ser el SLO
  más sano del sistema**, y ninguna alerta lo distingue (`SeriesAbsent` mira eventos totales, no
  presupuesto). Criterio de ingeniería, no norma citada: el arreglo es dar un lado izquierdo
  siempre presente al `bad` de disponibilidad, y eso toca las recording rules.
- **Esta alerta no tiene prueba de promtool** — TEL-30 la nombra explícitamente como prioritaria, y
  el grep sobre `VetSoftware/docker/tests/prometheus-slo.test.yml` lo confirma: no aparece.
- **TEL-05** — si el SLO afectado es `dian-transmission`, buena parte del presupuesto quemado puede
  venir de 401/403 de MATIAS contabilizados como `rejected`. El presupuesto es real; la causa que
  te sugiere la etiqueta, no.

---

### VetSoftwareSloErrorBudgetExhausted

**Qué significa** — Ese objetivo **está incumplido** en la ventana rodante de 30 días: se gastó
todo el margen de fallo y se sigue por debajo del compromiso. Es un hecho consumado, no una
emergencia: describe lo que ya pasó.

**Qué la dispara**

```promql
vetsoftware:slo_error_budget_remaining:ratio30d
```

con umbral `< 0`. Misma cadena que `ErrorBudgetLow`; solo cambia el tramo.

**`for: 30m`** — igual que la anterior: el valor se mueve en escala de días, la espera solo evita
oscilaciones.

**Severidad `warning` a propósito.** Se bajó de `critical` porque la severidad codifica **urgencia
de respuesta**, no gravedad del hecho: la ventana de 30 días describe daño ya registrado y a las 4
de la mañana no existe ninguna acción que cambie el número. En `critical` habría entrado en el
`repeat_interval` de 4 h — unas 180 notificaciones por un incidente que puede llevar días
arreglado, porque el dato malo no sale de la ventana hasta que envejece 30 días. **No se pierde
cobertura**: la emergencia en curso la cubre `VetSoftwareSloFastBurn`, que dispara en 2 minutos.
Esta alerta es el ticket que dice «este mes incumpliste», no el busca que dice «actúa ahora».

**Primero mirar**

1. **Por cuánto se incumple.** Y aquí hay una trampa: la serie está **acotada en −1**, así que `-1`
   significa «al menos el doble del presupuesto», no «exactamente el doble». La magnitud real está
   en:
   ```promql
   vetsoftware:slo_compliance:ratio30d
   vetsoftware:sli_bad:ratio_rate30d
   vetsoftware:slo_objective:ratio
   ```
   Compara `compliance` contra `objective`: esa diferencia sí es la de verdad.
2. **¿Sigue empeorando o ya se está recuperando?**
   ```promql
   vetsoftware:slo_burn_rate:ratio_rate1h
   vetsoftware:slo_burn_rate:ratio_rate1d
   ```
3. **Qué lo consumió** — igual que en `ErrorBudgetLow`, pasos 2 y 3: rango de 30 días sobre
   `vetsoftware:sli_bad_events:rate1d * 86400`.
4. **Comprobar si hay un FastBurn activo del mismo SLO.** Si lo hay, el incidente está vivo y la
   prioridad es esa alerta. Si no lo hay, esto es contabilidad del mes.

**Causas habituales**

1. **Un incidente prolongado ya conocido.** Hoy, en dev, `dian-transmission (availability)` está en
   `-1` por el documento atascado que falla el 100 % de los ciclos.
2. **Ventana parcial** en los primeros 30 días desde el despliegue de las reglas: un solo día
   catastrófico basta para dejarla negativa.
3. **Acumulación de varios incidentes menores** en el mismo mes.

**Qué hacer**

*Mitigación inmediata* — ninguna que mueva el número. Lo que sí toca hacer, y en este orden:
1. Comprobar si el incidente que lo causó sigue vivo (pasos 2 y 4).
2. Si sigue vivo, atenderlo por FastBurn/SlowBurn — esta alerta no es el canal.
3. Si ya está resuelto, **silencio con vencimiento** hasta la fecha en la que el día malo salga de
   la ventana de 30 días. Es el uso legítimo del silencio: el hecho es cierto, la notificación
   repetida no aporta.

*Arreglo de fondo*
- Solo deberían desplegarse correcciones de fiabilidad de ese dominio hasta que la ventana rodante
  recupere el presupuesto. Esa es la política, y es lo único que esta alerta pide.

**Cuándo NO es un incidente**

- **Nunca es un incidente en el sentido de «actúa ahora»** — por construcción. Si te llega de
  madrugada, apúntalo y sigue durmiendo; el `for: 30m` y el `group_wait: 5m` ya garantizan que no
  es una emergencia.
- **Ventana de 30 días incompleta** (mismo caveat que `ErrorBudgetLow`): hasta mediados de
  septiembre de 2026 el cálculo va sobre una ventana parcial.
- **`dian-transmission` en `-1` hoy es esperado y verdadero**: incidente real ya identificado.
  Silencio con vencimiento mientras se arregla, no descarte.

**Defectos conocidos de la señal**

- **El valor está acotado en −1 y pierde la magnitud.** `clamp_min(..., -1)` hace indistinguible
  «me pasé un 10 %» de «me pasé un 5.000 %». No uses este número para priorizar entre SLOs
  incumplidos; usa `slo_compliance:ratio30d` (paso 1). Criterio de ingeniería: el acotado es
  deliberado, pero su coste está aquí.
- **Ausencia de serie ≠ presupuesto sano.** Si un SLI de disponibilidad nunca tuvo un evento malo,
  la serie del presupuesto **no existe** y ni esta alerta ni `ErrorBudgetLow` dicen nada (ambas con
  `noDataState: OK`, que es correcto para evitar falsas alarmas). Detalle del mecanismo en el
  apartado equivalente de `VetSoftwareSloErrorBudgetLow`.
- **TEL-05** — en `dian-transmission`, el presupuesto quemado bajo la etiqueta `rejected` puede ser
  en realidad un fallo de credencial del proveedor.
- **TEL-01, contexto histórico** — hasta agosto de 2026 esta cadena solo evaluaba en el stack
  Docker local con métricas `_seconds_` y `job="vetsoftware"`; en Grafana Cloud dev nunca se
  evaluó. Los primeros 30 días de historia de presupuesto en cloud empiezan con el sync de estas
  reglas, no con la vida del servicio.

---

### VetSoftwareSloSeriesAbsent

**Qué significa** — Hay un objetivo declarado que **no se está midiendo**: en 24 horas no se
registró ni un solo evento de ese SLI. No dice que el servicio falle; dice que si fallara, no te
enterarías. Es la contra-prueba de la cadena SLO.

**Qué la dispara**

```promql
vetsoftware:slo_objective:ratio
unless
vetsoftware:sli_total_events:rate1d
```

con umbral `> 0`. La detección de ausencia la hace el `unless` **dentro** del PromQL: la expresión
devuelve una serie (con el valor del objetivo, siempre > 0) solo para los SLOs declarados que no
tienen serie de eventos en 24 h. El `threshold > 0` traduce «devolvió algo» a «dispara».

Por eso `noDataState: OK` es lo correcto aunque suene al revés: aquí **NoData significa que todos
los SLOs están produciendo eventos**, el caso sano. Ponerlo en `Alerting` invertiría la lógica y
dispararía justo cuando todo funciona. El hueco real —que `slo_objective:ratio` desaparezca en
bloque porque el ruler entero cayó— **no lo cubre nadie**; ver «Defectos conocidos».

**`for: 1h`** — una ausencia momentánea (el ruler recalculando, una ventana sin muestras) no es una
pérdida de medición. Una hora la distingue de un hueco real. Es `warning`, con `group_wait: 5m`:
~65 minutos hasta Slack.

**Primero mirar**

1. **Qué SLIs están sin medir** — la expresión de la alerta, tal cual:
   ```promql
   vetsoftware:slo_objective:ratio unless vetsoftware:sli_total_events:rate1d
   ```
   Verificado el 2026-08-19 en dev, devuelve exactamente seis: `auth-login/availability`,
   `clinical-write/availability`, `clinical-write/latency`, `inventory-movement/availability`,
   `pos-checkout/availability`, `pos-checkout/latency`.
2. **¿Es falta de tráfico o es un selector roto?** Enumera las rutas que sí existieron en 24 h
   —cuidado, mientras dev está apagado las series crudas desaparecen a los ~5 minutos, así que usa
   `count_over_time` y no una consulta instantánea:
   ```promql
   count by (uri, method) (count_over_time(http_server_requests_milliseconds_count{job="mainvet/vetsoftware"}[24h]))
   ```
   El 2026-08-19 esto devuelve solo `/actuator/health`, `/actuator/health/**`,
   `/auth/login/employee` (POST), `/auth/login/system` (POST), `/countries`,
   `/countries/{countryId}/states`, `/states/{stateId}/cities` y `/register` (POST). Ninguna ruta
   clínica, ninguna de POS: eso explica cuatro de los seis.
3. **Prueba el selector exacto de la regla** contra el crudo. Ejemplo para `pos-checkout`:
   ```promql
   count_over_time(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",method="POST",uri=~"(/api/v1)?/electronic-documents/from-sale"}[24h])
   ```
   Vacío con tráfico real en esa ruta = el selector está mal (el `uri` de Micrometer usa la
   plantilla del handler, sin context-path).
4. **Si el SLI es de latencia, comprueba el borde `le`.** Debe ser **entero**: `le="1000"` casa,
   `le="1000.0"` **no**, y el SLI desaparece en silencio.
   ```promql
   count by (le) (count_over_time(http_server_requests_milliseconds_bucket{job="mainvet/vetsoftware"}[24h]))
   ```
   Bordes utilizables por un SLI: HTTP `250, 500, 1000, 2000, 5000, 30000` (la métrica HTTP
   lleva además el histograma completo, 74 valores de `le` en total, pero los redondos son
   estos); DIAN duration `2000, 5000, 15000, 30000, 60000`. `lettuce` publicará
   `1, 5, 25, 50, 100` **cuando se despliegue** la imagen del backend que declara sus bordes;
   hoy solo tiene `+Inf`.
5. **Si es un SLI de negocio** (`dian-transmission`, `inventory-movement`), comprueba que la métrica
   exista:
   ```promql
   count by (result) (count_over_time(vetsoftware_business_inventory_movements_total[24h]))
   ```
   `vetsoftware_business_inventory_movements_total` **no existe todavía en cloud**: cero tráfico de
   inventario. El SLI queda inerte hasta el primer movimiento; es correcto, no un bug.
6. **¿Está el backend emitiendo algo?** Si la respuesta es «nada de nada», el problema no es un SLI:
   ```promql
   time() - max(max_over_time(timestamp(jvm_memory_used_bytes{job="mainvet/vetsoftware"})[24h:1m]))
   ```

**Causas habituales**

1. **La operación simplemente no se ejecutó.** En dev es la causa del 100 % de los casos actuales.
   En prod, un SLI crítico sin tráfico en 24 h sí merece explicación.
2. **Selector desalineado**: se renombró una ruta, cambió el `method`, o la métrica pasó a llamarse
   distinto en el mundo OTLP push (`_milliseconds_`, `job="mainvet/vetsoftware"`).
3. **Borde `le` en formato decimal** o umbral que no coincide con ningún borde publicado. El orden
   correcto es: primero se añade el borde en `management.metrics.distribution.slo` del backend,
   después se toca la regla.
4. **La métrica se está descartando por el filtro de cardinalidad** (TEL-04): un valor nuevo fuera
   de la allowlist tira el meter completo, sin contador y sin log.
5. **El backend lleva más de 24 h sin arrancar.**

**Qué hacer**

*Mitigación inmediata*
- **En dev**: silencio **con vencimiento** para las instancias conocidas. Nunca un silencio
  permanente ni desactivar la regla — se perdería la única contra-prueba de que la cadena SLO mide
  algo.
- **En prod**: tratar como fallo de medición, no de servicio. El orden de sospecha es selector →
  borde `le` → nombre de métrica → tráfico real; el objetivo es lo último que se toca.

*Arreglo de fondo*
- Si un SLI declarado no tiene tráfico en dev **por diseño**, la pregunta honesta es si ese SLO debe
  existir en dev. Un objetivo que solo se puede medir en prod puede declararse solo en prod; hoy las
  reglas son idénticas en los dos ambientes a propósito, y el precio es esta alerta permanente en
  dev.
- Si la causa fue un selector roto, añadir el caso a las pruebas de reglas: una convención sin
  prueba es una recomendación.

**Cuándo NO es un incidente**

- **En dev, casi nunca lo es — y aun así es un verdadero positivo.** La alerta dice la verdad
  (`auth-login`, `pos-checkout`, `clinical-write` e `inventory-movement` no se ejercitan en dev),
  pero la causa es benigna: esos endpoints no se llaman. **No es un falso positivo, es un positivo
  con causa conocida**, y la herramienta correcta es el silencio con vencimiento, no bajarle el
  `for` ni tocar la expresión.
- **Recién desplegadas las reglas**, todos los SLIs pueden aparecer ausentes durante la primera hora
  larga: `rate1d` necesita que el ruler haya grabado al menos una muestra.
- **`inventory-movement` seguirá ausente** hasta el primer movimiento de inventario real.

**Defectos conocidos de la señal**

- **Detecta «no hay eventos», nunca «los eventos son los equivocados».** Un SLI que mide una ruta
  minoritaria se ve perfectamente sano. Caso concreto y relevante: el SLI `pos-checkout` solo cuenta
  `POST /electronic-documents/from-sale`, la ruta del POS — y el hallazgo **TEL-08** documenta que
  el canal principal de facturación es el **cierre de cuenta** (`Channel.OPEN_ACCOUNT`), que no pasa
  por `RegisterPosSaleService`. La conclusión de que el SLO de checkout puede estar verde con el
  canal principal de facturación caído es **inferencia cruzando TEL-08 con el selector de la
  regla**, no una afirmación literal de la auditoría: conviene confirmar qué endpoint sirve el
  cierre de cuenta antes de actuar.
- **Si se cae la capa de reglas entera, esta alerta enmudece.** El `unless` necesita que
  `slo_objective:ratio` exista; si el ruler muere o alguien borra el namespace, desaparecen los dos
  lados, la expresión da vacío y `noDataState: OK` no alerta. Está documentado en el propio YAML
  como hueco aceptado. En prod lo cubre parcialmente el heartbeat (`vetsoftware-heartbeat-prod.yml`,
  que vigila `target_info` y `jvm_threads_live`); **en dev no lo cubre nada**, y no debe cubrirlo:
  dev se apaga a diario a propósito.
- **TEL-04 — el filtro de cardinalidad descarta sin dejar rastro.**
  `BusinessMetricCardinalityFilter.java:97-100` tira el meter completo sin contador, sin log y sin
  test de paridad con los enums de origen. Es la única causa de esta alerta que **no** deja ninguna
  huella en ningún sitio: si los pasos 2–5 dicen que hay tráfico y la métrica no aparece, es esto.
- **Discrepancia observada y no resuelta (2026-08-19).** `POST /auth/login/employee` y
  `POST /auth/login/system` **sí** tienen serie en las últimas 24 h, y aun así
  `auth-login/availability` no produce `sli_total_events:rate1d` y la alerta dispara para él. Las
  dos explicaciones plausibles son (a) que el tráfico ocurriera antes de que el ruler empezara a
  grabar estas reglas —se sincronizaron el 2026-08-19— o (b) que en ninguna ventana de 5 m hubiera
  dos muestras consecutivas de esa serie, con lo que `rate()` no produce nada. **No se ha podido
  distinguir con los datos disponibles.** Si esta instancia sigue disparando con tráfico de login
  reciente y confirmado, la sospecha (b) pasa a ser un defecto real de la cadena para SLIs de muy
  bajo volumen, y el arreglo es del lado de la regla, no del selector.
- **TEL-01, contexto** — hasta el 2026-08-19 ninguna de estas reglas evaluaba en el ambiente con
  tráfico real: vivían solo en el stack Docker local con `_seconds_` y `job="vetsoftware"`. Lo que
  esta alerta reporte durante los primeros días es el estreno de la medición, no una regresión.

---

## 2. HTTP y runtime de la JVM

### VetSoftwareHttp5xxRateHigh

**Qué significa** — Más de una de cada veinte respuestas del backend es un error del
servidor (500–599). No es que el cliente esté pidiendo mal: la petición llegó, el
backend la aceptó y no pudo atenderla. En dev, la causa número uno con diferencia es
la base de datos.

**Qué la dispara**

```promql
(
  sum by (deployment_environment_name) (
    rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri!~"/actuator.*",status=~"5.."}[5m])
  )
  /
  clamp_min(
    sum by (deployment_environment_name) (
      rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri!~"/actuator.*"}[5m])
    ),
    0.001
  )
)
and
sum by (deployment_environment_name) (
  increase(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri!~"/actuator.*"}[5m])
) >= 20
```

con umbral `> 0.05` en el nodo de comparación. Cuatro piezas:

- **La proporción**: 5xx sobre el total, en ventana móvil de 5 minutos. El
  `clamp_min(..., 0.001)` evita la división por cero cuando no hay tráfico.
- **`uri!~"/actuator.*"`, en el numerador y en el denominador** (corregido el
  2026-08-19). El SLI mide tráfico de **usuario**; la sonda de liveness era el 98,5 %
  del tráfico de dev y diluía cualquier fallo real hasta hacerlo invisible. Que el
  health check falle no es este incidente: eso lo cubren el heartbeat y ECS.
- **`by (deployment_environment_name)`**: dev y prod comparten `job`. Sin agrupar, el
  tráfico de prod cumpliría la guarda mientras los 5xx de dev entran en el numerador.
  Con el agrupado, la notificación además dice de qué entorno habla.
- **La guarda de volumen**: `>= 20` solicitudes de usuario en esos 5 minutos. No es el
  umbral de la alerta, es un filtro de presencia. Si no se cumple, el `and` vacía el
  resultado, la regla queda en NoData y `noDataState: OK` la deja apagada. El número
  no es arbitrario: **20 = 1/0,05**, por debajo de eso un solo 500 ya cruza el umbral
  del 5 % por sí mismo y la alerta pasa a significar «hubo un error», no «hay una tasa
  de error».
- **`for: 5m`** con `interval: 1m` = cinco evaluaciones consecutivas cumpliendo ambas
  condiciones. Cinco minutos sostenidos de 5xx ya es un incidente; menos convertiría
  cada despliegue rodante en una página.

Ojo con la interacción entre `for` y la guarda: **cualquier evaluación intermedia que
no llegue a 20 solicitudes reinicia el contador del `for`**, no lo pausa. En un
entorno de tráfico irregular la alerta puede no llegar a latchear aunque el fallo sea
real.

**Primero mirar**

1. **¿Sigue activa?** Grafana → Alerting → Alert rules → carpeta `VetSoftware`, grupo
   `vetsoftware-http`. **No hay notificación de resuelto**: el mensaje de Slack no se
   va a "cerrar" solo, el estado real solo está aquí.
2. **¿El backend está exportando?** `up` **no existe** en este stack —la ingesta es
   push por OTLP, no scrape—. La edad del último dato es la comprobación equivalente:

   ```promql
   time() - max(timestamp(jvm_memory_used_bytes{job="mainvet/vetsoftware",area="heap"}))
   ```

   Por encima de ~300 s no hay proceso exportando: deja de mirar HTTP y ve a ECS.
3. **Qué endpoint y qué excepción**:

   ```promql
   sum by (uri, method, status, exception, error) (
     increase(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",status=~"5.."}[15m])
   )
   ```
4. **Con qué se está comparando.** El denominador de la alerta ya **no** incluye la
   sonda de salud, pero esta consulta sí la muestra a propósito: ver cuánta de la
   actividad es sonda y cuánta es usuario es lo que te dice si el denominador de la
   alerta era siquiera significativo.

   ```promql
   sum by (uri) (increase(http_server_requests_milliseconds_count{job="mainvet/vetsoftware"}[15m]))
   ```
5. **Los logs de la misma ventana**, en el datasource `grafanacloud-logs`:

   ```logql
   {service_name="vetsoftware", deployment_environment_name="dev"} | json | level="ERROR"
   ```

   Cada línea trae `trace_id` y `span_id` en el JSON. Copia el `trace_id` y búscalo en
   `grafanacloud-traces` — el salto con un clic no está garantizado, ver defectos.
6. **¿Empezó con un despliegue?** Los logs **no** llevan `service_version`; las
   métricas sí:

   ```promql
   count by (service_version) (jvm_threads_live{job="mainvet/vetsoftware"})
   ```

   En las últimas 24 h dev pasó por `1.3.7-dev.1` → `1.4.0-dev.1` → `1.4.1-dev.1`: los
   despliegues son frecuentes y el cambio de versión es la primera hipótesis barata.
7. **Base de datos** — la causa más probable:

   ```promql
   hikaricp_connections_pending{job="mainvet/vetsoftware"}
   increase(hikaricp_connections_timeout_total{job="mainvet/vetsoftware"}[15m])
   ```

   y en AWS, el estado de la instancia RDS. En dev el `db.t4g.micro` encadena
   shutdown/recovery/restart por presión de memoria (ver `ALERTAS_OPERATIVAS.md` §5).
8. **Si la API no responde desde fuera pero aquí no hay 5xx**, no es el backend: es el
   túnel de Cloudflare, que es el único camino público. Log group
   `/ecs/vetsoftware-dev-backend/cloudflare-tunnel`. Un 5xx solo existe si la petición
   llegó a Spring.

**Causas habituales**

1. **Base de datos inaccesible** — `CannotCreateTransactionException` con `status=500`.
   Observado en vivo en dev sobre `/auth/login/system`. Es coherente con la
   inestabilidad conocida del `db.t4g.micro`.
2. **Despliegue con una versión rota** — correlaciona con el cambio de
   `service_version`.
3. **Pool de HikariCP agotado** — llega acompañada de
   `VetSoftwareDatabasePoolSaturated` o `VetSoftwareDatabaseConnectionTimeouts`.
4. **Dependencia externa que se propaga como 500** — MATIAS/DIAN, Resend, reCAPTCHA.
   El correo lleva semanas fallando el 100 % en dev (403, dominio sin verificar); si
   esa ruta deja de tragarse la excepción, aparece aquí.
5. **Presión de memoria o GC** — mira `VetSoftwareJvmHeapHigh` y
   `VetSoftwareJvmGcOverheadHigh` en el mismo intervalo.

**Qué hacer**

*Mitigación inmediata*

- Si es la base de datos: confirmar que la instancia RDS está `available` (puede estar
  `stopped` por el apagado programado o por el crash loop de memoria) y arrancarla con
  el workflow *Start dev environment*. No reiniciar a ciegas.
- Si es un despliegue: volver a la imagen anterior. El circuit breaker de ECS revierte
  solo cuando el despliegue no estabiliza, pero no cuando la tarea arranca sana y
  responde 500.
- Si es una dependencia externa: no hay interruptor. Documentar la ventana y seguir.

*Arreglo de fondo*

- ~~Excluir `/actuator/**` de la expresión~~ → hecho el 2026-08-19. Lo que queda por
  hacer es **generar tráfico de usuario en dev** (sintético): sin él, la exclusión deja
  esta alerta correctamente muda en dev, y la cobertura real solo existirá en prod.
- Los 5xx no distinguen hoy "fallo del backend" de "fallo de un proveedor". Una
  dimensión `error_type` acotada sobre la métrica HTTP sería la señal correcta;
  `exception` es un nombre de clase Java y no es una dimensión estable.

**Cuándo NO es un incidente**

- **Nunca por muestra pequeña**: la guarda de 20 lo impide por construcción. Si esta
  alerta dispara, hubo al menos 20 solicitudes **de usuario** en 5 minutos — un volumen
  que en dev no se alcanza nunca (línea base: ~11 al día). En dev, si esta alerta
  dispara, sospecha primero de una prueba de carga.
- Durante una prueba E2E o de carga que provoca errores a propósito.
- Los 4xx **no** cuentan aquí y no deben: una credencial mala o un 404 son el sistema
  funcionando.

**Defectos conocidos de la señal**

- ~~**La sonda de salud está dentro del numerador y del denominador.**~~ → **CORREGIDO
  2026-08-19.** `/actuator/**` está excluido de las dos sumas y de los buckets. Lo que
  se midió antes de corregirlo, por si hace falta interpretar datos antiguos: sobre 24 h
  de la etiqueta `uri`, `/actuator/health/**` = **748** peticiones y todo el resto junto
  = **11,4**. Es decir, el SLI era la sonda de liveness. Un fallo que rompiera la mitad
  de las peticiones de usuario daba una tasa agregada del 0,6 %, muy por debajo del 5 %.
- **La alerta sigue muda en dev — y ahora eso es correcto, no un defecto.** Con la sonda
  fuera, dev recibe ~**11 peticiones de usuario al día**. Verificado el 2026-08-19:
  `count_over_time((sum(increase(http_server_requests_milliseconds_count{uri!~"/actuator.*"}[5m])) >= 20)[7d:1m])`
  devuelve **vacío**: la guarda no se cumplió ni un solo minuto en siete días. No se
  puede calcular una tasa de error del 5 % con ese volumen, y bajar la guarda para «que
  suene algo» convertiría cada petición fallida suelta en un crítico. **Un solo número
  no sirve para dev y prod a la vez**, y PromQL no permite un umbral por entorno sin
  duplicar la regla (lo que obligaría a cambiar el `uid`, que es la clave de upsert del
  pipeline). La calibración de la regla es la de **prod**. En dev, la pregunta «¿el
  backend responde?» la contesta el heartbeat, no esta alerta. Si algún día se quiere
  señal HTTP real en dev, el camino es tráfico sintético (k6 / synthetic monitoring), no
  rebajar la guarda.
- **Interacción `for` × guarda, que sigue vigente.** Cualquier evaluación intermedia que
  no llegue a 20 solicitudes **reinicia** el contador del `for`, no lo pausa. En tráfico
  irregular la alerta puede no llegar a latchear aunque el fallo sea real. Es el precio
  de un SLI basado en proporción; la alternativa —conteo absoluto de 5xx— no lo tiene,
  pero tampoco distingue «diez errores sobre diez peticiones» de «diez sobre un millón».
- **TEL-03 — el paso 5 (Loki) llega ruidoso.** Unos 35 handlers de dominio del
  `GlobalExceptionHandler` registran 4xx (404, 409, 400) como `WARN`, contradiciendo la
  regla que el propio archivo documenta en `handleExceptionInternal` (líneas 205–218,
  que sí los baja a INFO). `level=warn` está dominado por "Resource not found" de
  clientes equivocándose. Filtra por `level="ERROR"`, no por `WARN`.
- **TEL-16 — la consulta cruzada se escribe dos veces.** El MDC usa `http.method`
  (deprecado en semconv), `http.path` (no existe) y `client.ip` (deprecado), mientras
  la métrica usa `uri`/`method`. No hay una sola clave que sirva para las dos señales.
- **TEL-01 — el runbook viejo manda a una métrica inexistente.**
  `VetSoftware/docs/ALERTAMIENTO_OPERATIVO.md` líneas 93–97 dice "agrupe
  `http_server_requests_seconds_count`". Esa familia **no existe en Grafana Cloud**:
  aquí es `_milliseconds_`. Devuelve vacío. Este fragmento la sustituye.
- **TEL-37 — los logs de dev no llevan `service_version`.** Métricas y trazas sí. Por
  eso el paso 6 va por la métrica y no por Loki.
- **No hay reglas de inhibición en el motor de Grafana.** Si el incidente degrada
  también la latencia, llegarán a Slack tres mensajes independientes (`Http5xxRateHigh`,
  `HttpP99LatencyCritical`, `HttpP95LatencyHigh`) para un solo incidente. Es esperado,
  no un fallo del sistema de alertas.
- **TEL-30 — sin prueba automática.** Solo 12 de las 37 alertas declaradas tienen
  prueba de `promtool`, y las reglas Grafana-managed de este archivo no son verificables
  con `promtool` en absoluto (formato distinto). No se pudo verificar que esta regla en
  concreto tenga cobertura: **asume que no la tiene**.
- **La ventana de mantenimiento de AWS no aplica aquí.** Las mute rules de
  `ALERTAS_OPERATIVAS.md` §6 (19:55–08:05 y fines de semana) silencian **alarmas de
  CloudWatch**, no reglas de Grafana. Lo único que evita el ruido nocturno de esta
  alerta es `noDataState: OK`.

---

### VetSoftwareHttpP99LatencyCritical

**Qué significa** — Una de cada cien peticiones tarda más de dos segundos, y lleva así
diez minutos. La mayoría de usuarios no lo nota; los que lo notan, lo notan mucho.

**Qué la dispara**

```promql
histogram_quantile(
  0.99,
  sum by (le, deployment_environment_name) (
    rate(http_server_requests_milliseconds_bucket{job="mainvet/vetsoftware",uri!~"/actuator.*"}[5m])
  )
)
and
sum by (deployment_environment_name) (
  increase(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri!~"/actuator.*"}[5m])
) >= 100
```

con umbral `> 2000`. **La unidad es milisegundos**, no segundos: el backend exporta por
OTLP push y Micrometer emite timers en `ms`. Escribir `2` en vez de `2000` produciría
una alerta permanente.

- **El umbral cae exactamente sobre un borde `le` publicado.** `application.yml:167`
  declara `slo: http.server.requests: 250ms,500ms,1s,2s,5s`, así que existe un bucket
  con `le="2000"` — verificado en la señal real. `histogram_quantile` no tiene que
  interpolar alrededor del umbral. **Si alguien mueve el umbral, hay que añadir antes el
  borde**: un umbral entre bordes hace que el SLI se degrade en silencio en vez de
  fallar de forma visible.
- **El filtro `uri!~"/actuator.*"`** (2026-08-19) saca la sonda de liveness también de
  aquí. El filtro es de etiqueta, no de bucket: los seis bordes `le`
  (250/500/1000/2000/5000/30000) siguen publicados después de filtrar — verificado con
  `count by (le)`. El umbral no se movió y sigue cayendo sobre un borde exacto.
- **La guarda de esta alerta es ≥ 100, no ≥ 20 como las otras dos.** No es prudencia:
  **100 = 1/(1−0,99)**. Con menos muestras el "p99" es literalmente la petición más
  lenta del lote, y un único outlier —un cold start, una consulta puntual— dispararía
  un **crítico**. La guarda de 20 es la correcta para el p95 (1/(1−0,95)) y para la
  tasa de 5xx (1/0,05); para el p99 se queda corta por un factor de cinco.
- **`for: 10m`** con ventana `rate[5m]`: una sola petición lenta influye durante 5
  minutos, así que **no puede latchear sola**. Hacen falta al menos dos episodios
  separados o degradación sostenida. Es la propiedad que hace usable esta alerta con
  poco tráfico.
- **`by (deployment_environment_name)`**, igual que en la de 5xx: dev y prod comparten
  `job` y no deben compartir percentil.

**Primero mirar**

1. **¿Sigue activa?** Alerting → Alert rules, grupo `vetsoftware-http`. No hay aviso de
   resuelto.
2. **Qué endpoint** — la alerta agrega sobre *todas* las rutas y no te lo dice:

   ```promql
   histogram_quantile(0.99,
     sum by (le, uri) (rate(http_server_requests_milliseconds_bucket{job="mainvet/vetsoftware"}[5m]))
   )
   ```
3. **Cuántas muestras hay detrás** — antes de creerte el número:

   ```promql
   sum by (uri) (increase(http_server_requests_milliseconds_count{job="mainvet/vetsoftware"}[5m]))
   ```

   Si es del orden de 20, el "p99" **es la petición más lenta de la ventana**, no un
   percentil. Compáralo con la media, que sí es honesta con pocas muestras:
   `sum(rate(http_server_requests_milliseconds_sum[5m])) / sum(rate(http_server_requests_milliseconds_count[5m]))`.
4. **Descartar GC** — es la causa que más se olvida y la más barata de descartar:

   ```promql
   jvm_gc_overhead{job="mainvet/vetsoftware"}
   jvm_gc_pause_max_milliseconds{job="mainvet/vetsoftware"}
   sum by (gc, action, cause) (increase(jvm_gc_pause_milliseconds_sum{job="mainvet/vetsoftware"}[5m]))
   ```

   Los pools son `Eden Space` / `Survivor Space` / `Tenured Gen`: **SerialGC**. Con
   `system_cpu_count = 1` (verificado), un full GC es monohilo y stop-the-world: se
   traduce directamente en cola de peticiones.
5. **Descartar la base de datos**: `hikaricp_connections_pending`,
   `hikaricp_connections_active`, y en CloudWatch `database-read-latency` /
   `database-disk-queue` / `database-cpu-credits-low`. Un `db.t4g.micro` sin créditos
   de ráfaga "de repente está lento" sin que ninguna métrica clásica lo explique.
6. **Descartar CPU**: `process_cpu_usage{job="mainvet/vetsoftware"}` y, en CloudWatch,
   `CPUUtilization` del servicio ECS. La tarea corre en **Fargate Spot con 512 unidades
   de CPU (0,5 vCPU)**: no hay ráfaga que absorba un pico.
7. **Las trazas** — es lo único que dice *dónde* se fue el tiempo. En
   `grafanacloud-traces`:

   ```traceql
   {resource.service.name="vetsoftware" && duration > 2s}
   ```

   Ese salto hay que darlo a mano: el exemplar del panel no funciona (ver defectos).
8. **Tormenta de logs**: si en la misma ventana el volumen de logs se dispara, mira el
   defecto de `RedactingAppender` más abajo. El sistema de logging puede ser la causa
   de la latencia, no su testigo.

**Causas habituales**

1. **Base de datos lenta** — créditos EBS/CPU agotados, swap, o el buffer pool reducido
   por RDS-EVENT-0403. Es la primera hipótesis en dev.
2. **Arranque en frío** — tras un despliegue o una interrupción de Spot: JIT sin
   calentar, pool de conexiones vacío, caches vacías. El `startPeriod` del health check
   es de 180 s; el `for: 10m` normalmente lo cubre, pero no siempre.
3. **Pausas de GC** — ver paso 4.
4. **Proveedor externo sin timeout apretado** — MATIAS/DIAN, Resend, reCAPTCHA. Un
   cliente HTTP sin timeout convierte la latencia ajena en latencia propia.
5. **Contención en el appender de logs** — ver defectos.

**Qué hacer**

*Mitigación inmediata*

- Si es GC o heap, un despliegue nuevo reinicia la JVM y compra tiempo. **Captura antes**
  `jvm_gc_live_data_size_bytes` y el heap por pool: el reinicio destruye la evidencia.
- Si es la base de datos, no hay mitigación desde el backend. Confirmar el estado de la
  instancia.
- Si es un proveedor externo, no hay interruptor hoy.

*Arreglo de fondo*

- ~~Excluir `/actuator/**` de la expresión~~ → hecho el 2026-08-19.
- **La alerta debería llevar `by (uri)`**, o al menos declarar el endpoint en la
  anotación. Hoy el mensaje de Slack dice que algo está lento y nada más.
- Timeouts explícitos en los clientes HTTP salientes: es lo que convierte un problema
  de latencia en un problema de error, que sí es accionable.

**Cuándo NO es un incidente**

- **Los primeros minutos tras un despliegue o tras una interrupción de Spot.** El
  `for: 10m` filtra la mayoría, pero no todo: si el arranque coincide con carga real,
  puede latchear. Comprueba el paso 6 (`service_version`) antes de investigar nada más.
- Un job programado pesado corriendo en paralelo con poco tráfico HTTP: el p99 se
  degrada por contención de CPU sobre 0,5 vCPU, no por un defecto del endpoint.
- **Con 20–30 muestras, p99 y p95 son la misma petición.** Si llegan
  `HttpP99LatencyCritical` y `HttpP95LatencyHigh` a la vez, es un incidente, no dos.

**Defectos conocidos de la señal**

- ~~**Un p99 sobre 20 muestras no es un p99.**~~ → **CORREGIDO en parte, 2026-08-19**: la
  guarda subió a **100 = 1/(1−0,99)**, que es el mínimo por debajo del cual el
  estadístico directamente no existe. Sigue siendo un mínimo, no un ideal: para que un
  p99 sea *estable* (poco ruido entre ventanas) el orden de magnitud es **1.000**
  muestras. Con 100–200 el número es interpretable pero salta. **No lo llames p99 en un
  informe sin decir cuántas muestras había detrás** — el paso 3 lo responde. La
  formulación alternativa, que no necesita ninguna guarda porque no es un cociente ni un
  cuantil, es contar peticiones por encima del umbral:
  `sum(rate(http_server_requests_milliseconds_count{uri!~"/actuator.*"}[5m])) - sum(rate(http_server_requests_milliseconds_bucket{uri!~"/actuator.*",le="2000"}[5m]))`.
- **TEL-28 — la correlación métrica→traza está rota en dev.** Los exemplars **sí llegan**
  al stack, pero el datasource de Prometheus de Grafana Cloud (provisionado, `readOnly`)
  espera el campo `traceID` y lo que llega es `trace_id`. Consecuencia práctica: ves el
  p99 alto y **no tienes ni una traza de ejemplo con un clic**. Es exactamente el minuto
  que más cuesta a las 3 de la mañana. El arreglo es un ticket a Soporte de Grafana
  Cloud para corregir `exemplarTraceIdDestinations` — lo ejecuta el dueño de la cuenta,
  no se puede hacer desde el repo. Mientras tanto: paso 7, TraceQL a mano.
- **TEL-17 — el logging amplifica su propio incidente.**
  `VetSoftware/src/main/java/com/vetsoftware/app/infrastructure/logging/RedactingAppender.java:50`
  extiende `AppenderBase`, cuyo `doAppend` es `synchronized`: **toda la redacción por
  expresiones regulares de todos los hilos se serializa en un único lock**. En una
  tormenta de errores —justo cuando más se loguea— los hilos de request se encolan en
  el lock de logging y la latencia sube por el propio sistema de observación. Con 0,5
  vCPU el efecto es peor. Arreglo: extender `UnsynchronizedAppenderBase`.
- ~~**La sonda de salud tira del cuantil hacia abajo.**~~ → **CORREGIDO 2026-08-19**:
  `uri!~"/actuator.*"` en los buckets y en la guarda. Antes, `/actuator/health/**` era
  748 de las 759 peticiones de 24 h y su latencia (p95 medido: 5–20 ms) aplastaba el
  cuantil, enmascarando cualquier endpoint de negocio lento.
- **La alerta no dice qué endpoint.** `sum by (le)` colapsa `uri`. Es correcto para un
  SLI global y pésimo para un aviso operativo. Sigue abierto.
- **Muda en dev, ahora por la razón correcta.** Con la sonda fuera, dev tiene ~11
  peticiones de usuario al día: un p99 no existe con eso, y la guarda de 100 no se
  cumple nunca. La calibración es la de prod. Mismo razonamiento y mismos datos que en
  `VetSoftwareHttp5xxRateHigh`.
- **Cardinalidad**: con `percentiles-histogram: true` cada combinación
  (`uri`, `method`, `status`, `outcome`, `exception`, `error`) cuesta **~74 series** de
  bucket. Medido: 74 series de `_bucket` en reposo, 370 en el pico de las últimas 24 h.
  Añadir una etiqueta nueva a la métrica HTTP multiplica por 74, no por 1. Y el tag
  `error` que añade `Observation.error()` **no está acotado por ningún `MeterFilter`**
  —el filtro de cardinalidad solo cubre el prefijo `vetsoftware.business.` (TEL-18)—;
  hoy su único valor observado es `none`, pero nada impide que mañana sean nombres de
  clase de excepción.

---

### VetSoftwareHttpP95LatencyHigh

**Qué significa** — Una de cada veinte peticiones tarda más de un segundo, sostenido
diez minutos. Es la versión temprana y menos grave de la anterior: mucha gente lo nota,
pero el sistema responde.

**Qué la dispara**

```promql
histogram_quantile(
  0.95,
  sum by (le, deployment_environment_name) (
    rate(http_server_requests_milliseconds_bucket{job="mainvet/vetsoftware",uri!~"/actuator.*"}[5m])
  )
)
and
sum by (deployment_environment_name) (
  increase(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri!~"/actuator.*"}[5m])
) >= 20
```

con umbral `> 1000` (**milisegundos**) y `for: 10m`. Es la misma expresión que
`VetSoftwareHttpP99LatencyCritical` cambiando el cuantil y el umbral, y **el umbral
también cae sobre un borde `le` publicado** (`1s` en la lista `slo` de
`application.yml:167`) — verificado en la señal real.

**La guarda se queda en 20, no sube a 100 como la del p99**: 20 = 1/(1−0,95) es el
mínimo por debajo del cual el p95 deja de ser un percentil. Las dos guardas se derivan
de la misma fórmula y salen distintas porque los cuantiles lo son.

Severidad `warning` frente a `critical`: la diferencia no es la gravedad percibida sino
la accionabilidad. Un p95 por encima de un segundo pide investigar dentro del horario
laboral; un p99 por encima de dos, ahora.

**Primero mirar**

Los mismos ocho pasos de `VetSoftwareHttpP99LatencyCritical`, cambiando `0.99` por
`0.95` y `duration > 2s` por `duration > 1s` en TraceQL. Añade dos:

1. **Compara con el p50.** Si el p50 también subió, no es una cola larga: es
   degradación general y la causa está aguas abajo (BD, CPU, GC), no en un endpoint.

   ```promql
   histogram_quantile(0.50, sum by (le) (rate(http_server_requests_milliseconds_bucket{job="mainvet/vetsoftware"}[5m])))
   ```
2. **Mira si el p99 también está en alerta.** Si sí, atiende ese y este se resolverá
   solo: es el mismo incidente contado dos veces (no hay inhibición en el motor de
   Grafana).

**Causas habituales**

Idénticas a las del p99, en el mismo orden. La diferencia es la magnitud, no la
naturaleza: la latencia raramente se degrada solo en la cola.

Una causa propia del p95 y no del p99: **cambia la composición del tráfico de usuario**.
Si llega de golpe una demo o una prueba E2E con endpoints más pesados que los habituales,
el p95 sube sin que nada haya empeorado. (Hasta el 2026-08-19 esta causa era mucho más
frecuente y de otra naturaleza: la sonda de salud estaba dentro del cuantil y cualquier
tráfico real la desplazaba. Ya no aplica: `/actuator/**` está excluido.)

**Qué hacer**

*Mitigación inmediata* — normalmente ninguna. Un p95 warning que no viene acompañado
del p99 critical se investiga, no se mitiga a golpes.

*Arreglo de fondo* — los mismos que el p99: añadir `by (uri)`, timeouts en los clientes
salientes, y `UnsynchronizedAppenderBase` en el appender de redacción. (Excluir
`/actuator/**` ya está hecho, 2026-08-19.)

**Cuándo NO es un incidente**

- **Llegada acompañando al p99 critical**: es un solo incidente, no dos. Silencia
  mentalmente este y atiende aquel.
- Arranque en frío tras despliegue o interrupción de Spot.
- Cambio de composición del tráfico (más peticiones de negocio, menos health checks).
  Compruébalo con `sum by (uri) (rate(http_server_requests_milliseconds_count[5m]))`
  antes de investigar el código.

**Defectos conocidos de la señal**

- **Los del p99 que siguen abiertos**: exemplars rotos (TEL-28), la alerta sin
  `by (uri)`, el lock del `RedactingAppender` (TEL-17) y las ~74 series por combinación
  de etiquetas. La sonda dentro del cuantil está **corregida** (2026-08-19).
- **Un p95 sobre 20 muestras es la muestra número 19.** La guarda de 20 es el mínimo
  matemático (1/(1−0,95)), no un objetivo: para que un p95 sea *estable* entre ventanas
  hacen falta del orden de **200** muestras. Con 20–30, este p95 y el p99 son la misma
  petición y llegarán juntos.
- **Muda en dev, por la razón correcta.** Sin la sonda, dev tiene ~11 peticiones de
  usuario al día. La calibración de la guarda es la de prod; ver el detalle en
  `VetSoftwareHttp5xxRateHigh`.
- **Este par de alertas comparte expresión con la cadena de SLO del repo, que evalúa en
  otro sitio.** Las reglas de burn rate multiventana viven en el stack Docker local
  contra `http_server_requests_seconds_*` y no evalúan en dev (TEL-01). Si alguien te
  dice "el error budget está bien", ese dato no existe para este entorno.

---

### VetSoftwareJvmHeapHigh

**Qué significa** — La JVM lleva diez minutos usando más del 85 % del heap que tiene
disponible. Puede ser carga real, puede ser una fuga. Si es fuga, el final es que el
proceso muere.

**Qué la dispara**

```promql
sum(jvm_memory_used_bytes{job="mainvet/vetsoftware",area="heap"})
/
clamp_min(sum(jvm_memory_max_bytes{job="mainvet/vetsoftware",area="heap"}), 1)
```

con umbral `> 0.85` y `for: 10m`. Sin guarda de volumen: es un gauge, siempre está ahí
mientras el proceso viva. El `clamp_min(..., 1)` evita la división por cero en el
instante del arranque, antes de que los pools publiquen su máximo.

`for: 10m` es lo que separa "el heap está lleno" de "Eden se llenó y el GC lo vació",
que es el comportamiento normal de un recolector generacional. Con menos, esta alerta
sería un generador de ruido.

**Valores reales medidos en dev el 2026-08-19**: el cociente oscila entre **0,10 y
0,21**. El umbral está a más de cuatro veces el máximo observado.

**Primero mirar**

1. **La serie completa en 6 h**, no el instante:

   ```promql
   sum(jvm_memory_used_bytes{job="mainvet/vetsoftware",area="heap"})
   / clamp_min(sum(jvm_memory_max_bytes{job="mainvet/vetsoftware",area="heap"}), 1)
   ```
2. **Desglosa por pool** — esto es lo que decide si hay incidente:

   ```promql
   jvm_memory_used_bytes{job="mainvet/vetsoftware",area="heap"}
   ```

   Si lo que sube y baja en sierra es `Eden Space`, es funcionamiento normal. Si lo que
   crece de forma monótona es **`Tenured Gen`**, hay objetos que sobreviven a los GC y
   eso sí es una fuga.
3. **El indicador real de fuga** — tamaño vivo tras el GC completo. Ambas series
   existen en dev (verificado):

   ```promql
   jvm_gc_live_data_size_bytes{job="mainvet/vetsoftware"}
   / clamp_min(jvm_gc_max_data_size_bytes{job="mainvet/vetsoftware"}, 1)
   ```

   **Este cociente, no el de la alerta, es el que hay que mirar para decidir si es
   fuga.** Si sube de forma monótona a lo largo de horas, es fuga; si vuelve a su línea
   base tras cada GC completo, es carga.
4. **La presión del GC**: `jvm_gc_overhead` y
   `sum by (cause, action) (increase(jvm_gc_pause_milliseconds_sum{job="mainvet/vetsoftware"}[15m]))`.
   Fuga en fase terminal = GC completos consecutivos que no liberan nada.
5. **¿Empezó con un despliegue?**
   `count by (service_version) (jvm_threads_live{job="mainvet/vetsoftware"})`.
6. **La memoria del contenedor, en CloudWatch**, que es un número distinto:
   `backend-high-memory` (> 85 %, 2 de 2 × 5 min) y `backend-memory-exhausted`
   (> 92 % de máximos por minuto, 3 de 5). Ver `ALERTAS_OPERATIVAS.md` §2. La tarea
   incluye metaspace, hilos, memoria directa y el sidecar `cloudflared`: el heap es solo
   una parte.
7. **¿Ya murió?**

   ```logql
   {service_name="vetsoftware", deployment_environment_name="dev"} |= "OutOfMemoryError"
   ```

   La JVM arranca con `-XX:+ExitOnOutOfMemoryError`: un OOM **mata el proceso**, ECS
   reemplaza la tarea y lo verás además como `backend-task-restart`.

**Causas habituales**

1. **Fuga o caché sin cota** — el patrón clásico: `Tenured Gen` monótono creciente.
2. **Carga real** — reconciliación DIAN, generación de PDF/QR, un listado sin paginar.
   Sube y baja.
3. **Heap mal dimensionado tras cambiar la memoria de la tarea** — `backend_memory` pasó
   de 2048 a 3072 MiB; `MaxRAMPercentage=70.0` reparte sobre lo que quede tras descontar
   los 128 MiB de `cloudflared`.
4. **Snapshot de métricas de negocio** (`BusinessGaugeMetrics`) reteniendo estructuras
   más grandes de lo previsto.

**Qué hacer**

*Mitigación inmediata*

- Si el paso 3 confirma fuga, un despliegue nuevo reinicia la JVM y compra horas.
  **Antes de reiniciar, captura**: `jvm_gc_live_data_size_bytes`, el desglose por pool y
  la ventana de logs. El reinicio borra la única evidencia que había.
- Si es carga real y puntual, no hagas nada: el `for: 10m` ya filtró lo transitorio.

*Arreglo de fondo*

- **No subas `backend_memory` sin descartar antes una fuga.** Es literalmente lo que
  dice `ALERTAS_OPERATIVAS.md` §7 para la alarma de memoria del contenedor, y aplica
  igual aquí: más memoria solo alarga el intervalo entre reinicios.
- Cambiar la alerta para que vigile `jvm_gc_live_data_size_bytes /
  jvm_gc_max_data_size_bytes` en vez del heap ocupado. Es la señal correcta y no cuesta
  ninguna serie nueva: ambas ya se emiten.

**Cuándo NO es un incidente**

- **Un 85 % instantáneo es normal con un recolector generacional.** El heap ocupado sube
  hasta llenar Eden y cae de golpe. Por eso hay `for: 10m` — y por eso un pantallazo
  del panel no prueba nada.
- **Durante el arranque**: carga del contexto de Spring, Liquibase, calentamiento de
  caches. El `startPeriod` del health check es de 180 s; los diez minutos del `for` lo
  cubren de sobra.
- Con los valores reales de dev (0,10–0,21) esta alerta **no ha estado ni cerca** de
  disparar. Si llega, es un cambio de régimen, no ruido.

**Defectos conocidos de la señal**

- **El denominador no es `-Xmx`.** Verificado en la señal real: los máximos por pool son
  `Eden Space` 576.651.264 B (550,0 MiB), `Survivor Space` 72.024.064 B (68,7 MiB) y
  `Tenured Gen` 1.441.464.320 B (1.374,7 MiB); su suma es **1.993,3 MiB**. Reconstruido
  desde la configuración (`backend_memory = 3072` MiB menos 128 MiB de `cloudflared`
  = 2.944 MiB para el contenedor, por `MaxRAMPercentage=70.0` de
  `environments/dev/locals.tf:85`) el `-Xmx` real es **≈ 2.060,8 MiB** — y las
  proporciones Eden/Survivor observadas lo confirman con exactitud. La diferencia es el
  **espacio Survivor inactivo**, que el heap nunca puede usar a la vez. Consecuencia: la
  alerta dispara al 85 % de 1.993,3 MiB, que es el **82,2 % del `-Xmx` real**. Es el
  lado seguro del error (avisa antes), pero el porcentaje del mensaje **no es "% de
  `-Xmx`"** y no debe citarse como tal en un informe.
- **`ALERTAS_OPERATIVAS.md` §2 está desactualizado en la aritmética.** Razona sobre
  "los 2048 MiB de la tarea"; el valor por defecto vigente en
  `environments/dev/variables.tf` es **3072**. La conclusión de esa sección (el umbral
  de 92 % de memoria de contenedor) sigue siendo válida, pero los números intermedios no
  cuadran. Corregirlo es de infraestructura, no de telemetría.
- **`sum()` sin `by (instance)` mezcla JVMs.** Durante un despliegue rodante conviven
  dos tareas: el cociente agregado puede quedarse en 0,70 con una de las dos JVM al
  95 %. En dev con `desired_count = 1` casi nunca ocurre; en un despliegue, sí.
- **`instance` y `service_instance_id` valen la constante `ecs-fargate-spot`**, no el ID
  de la tarea (verificado en las etiquetas reales). OTel semconv exige que
  `service.instance.id` sea **único por instancia**. Consecuencia directa: aunque
  añadieras `by (instance)`, **seguirías sin poder distinguir dos tareas**; lo único que
  las separa hoy es `service_version`, y solo si son versiones distintas. Es un defecto
  de la configuración del recurso, no de la alerta, y afecta por igual a las cuatro
  alertas de runtime de este bloque.
- **El ratio de heap ocupado no es un indicador de fuga.** Ver paso 3. La alerta mide lo
  fácil de medir, no lo que decide el incidente.

---

### VetSoftwareJvmGcOverheadHigh

**Qué significa** — La JVM está gastando más de un 20 % de su tiempo recogiendo basura
en vez de atender peticiones. Es el aviso que precede a la degradación severa: todavía
hay memoria, pero conseguirla cuesta cada vez más.

**Qué la dispara**

```promql
jvm_gc_overhead{job="mainvet/vetsoftware"}
```

con umbral `> 0.20` y `for: 10m`. Es un gauge que publica Micrometer
(`JvmHeapPressureMetrics`) y que ya viene calculado como fracción del tiempo de CPU
dedicado a GC **sobre una ventana móvil propia** (5 minutos en la configuración por
defecto de Spring Boot; no está sobrescrito en el repo).

El `for: 10m` filtra el full GC aislado del arranque o de un job puntual. `0.20` es un
umbral convencional: por encima de ahí el rendimiento se degrada de forma perceptible
aunque el heap no esté lleno.

**Valor real medido en dev el 2026-08-19**: prácticamente **0**, con un máximo de
`2,3 × 10⁻⁵`. El umbral está a cuatro órdenes de magnitud.

**Primero mirar**

1. **La serie en 6 h**: `jvm_gc_overhead{job="mainvet/vetsoftware"}`. Confirma que es
   sostenido y no un artefacto de un solo punto.
2. **Qué GC y por qué causa** — aquí está el diagnóstico:

   ```promql
   sum by (gc, action, cause) (increase(jvm_gc_pause_milliseconds_sum{job="mainvet/vetsoftware"}[15m]))
   sum by (gc, action, cause) (increase(jvm_gc_pause_milliseconds_count{job="mainvet/vetsoftware"}[15m]))
   jvm_gc_pause_max_milliseconds{job="mainvet/vetsoftware"}
   ```

   `action="end of major GC"` repetido con `cause="Allocation Failure"` es el patrón de
   fuga en fase terminal.
3. **¿Libera algo el GC?** — la pregunta que decide todo:

   ```promql
   jvm_gc_live_data_size_bytes{job="mainvet/vetsoftware"}
   / clamp_min(jvm_gc_max_data_size_bytes{job="mainvet/vetsoftware"}, 1)
   ```

   Si el tamaño vivo crece tras cada GC completo, es fuga y el siguiente paso es
   `VetSoftwareJvmHeapHigh` y, después, un OOM.
4. **La tasa de asignación** — distingue fuga de "código que genera basura a espuertas":

   ```promql
   rate(jvm_gc_memory_allocated_bytes_total{job="mainvet/vetsoftware"}[5m])
   ```
5. **El impacto**: ¿está también en alerta el p95/p99? Con **SerialGC** (los nombres de
   pool `Eden Space`/`Tenured Gen` lo confirman) y **1 CPU visible para la JVM**
   (`system_cpu_count = 1`, verificado), un full GC es monohilo y stop-the-world: cada
   pausa es latencia de request, sin excepción.
6. **¿Empezó con un despliegue?**
   `count by (service_version) (jvm_threads_live{job="mainvet/vetsoftware"})`.

**Causas habituales**

1. **Heap insuficiente para la carga** — el GC trabaja al límite para mantener el hueco.
2. **Fuga en fase terminal** — GC completos consecutivos que no recuperan nada. Se
   confirma con el paso 3.
3. **Asignación masiva** — generación de PDF/QR, un listado sin paginar, una consulta
   que trae la tabla entera. Alta tasa de asignación con tamaño vivo estable.
4. **SerialGC sobre 0,5 vCPU** — no es una causa por sí sola, pero multiplica el efecto
   de las tres anteriores.

**Qué hacer**

*Mitigación inmediata*

- Si el paso 3 dice fuga: despliegue nuevo, tras capturar evidencia. Es lo mismo que en
  `VetSoftwareJvmHeapHigh`.
- Si es asignación masiva por un job: comprobar si se puede posponer.

*Arreglo de fondo*

- Arreglar la asignación (paginar, transmitir en flujo, no materializar) antes que subir
  memoria.
- **El recolector es una decisión pendiente, no un accidente**: con 1 CPU visible la JVM
  elige SerialGC. Si la carga crece, forzar G1 exige también revisar la CPU de la tarea;
  G1 sobre 0,5 vCPU no mejora nada.

**Cuándo NO es un incidente**

- Un full GC durante el arranque o justo después de un despliegue. El `for: 10m` sumado
  a la ventana interna de Micrometer lo filtra.
- Un job programado pesado que corre una vez y termina.
- Con los valores reales de dev (≈ 0) esta alerta **nunca ha disparado**. No hay
  evidencia empírica de que sea sensible en este entorno; trátala como no calibrada.

**Defectos conocidos de la señal**

- **Llega tarde por construcción.** `jvm_gc_overhead` ya promedia sobre una ventana
  móvil de 5 minutos, y encima lleva `for: 10m`: entre que el GC empieza a comerse la
  CPU y que suena Slack pueden pasar **quince minutos**. Para un incidente de GC eso es
  media vida. El indicador adelantado es `jvm_gc_pause_max_milliseconds` y el paso 3;
  úsalos tú, porque la alerta no los mira.
- **No se pudo verificar la ventana interna configurada.** No hay ninguna referencia a
  `JvmHeapPressureMetrics` en el código del backend, así que se está usando el
  autoconfigurado de Spring Boot y se asume su valor por defecto documentado por
  Micrometer (5 minutos de *lookback*). **No se comprobó contra el proceso en ejecución.**
- **Umbral sin calibrar contra este entorno.** 0,20 es el valor convencional del sector,
  y la línea base observada es ~0. Entre 0 y 0,20 hay un rango enorme sin vigilancia: un
  overhead sostenido del 10 % ya sería degradación clara y no dispara nada. Criterio: un
  umbral secundario de `warning` en 0,05 daría aviso útil; hoy la señal es binaria entre
  "perfecto" y "roto".
- **`instance`/`service_instance_id` no identifican la tarea** (constante
  `ecs-fargate-spot`). Ver el mismo defecto detallado en `VetSoftwareJvmHeapHigh`.
- **Sin prueba automática** (TEL-30): las reglas Grafana-managed no son verificables con
  `promtool`, y no existe un gate equivalente. Una regla sin prueba es una
  recomendación.

---

### VetSoftwareJvmThreadCountHigh

**Qué significa** — La JVM tiene más de 200 hilos vivos. Lo normal en dev son entre 29 y
35, así que si esto suena, algo está creando hilos que no debería o hay muchísimos hilos
bloqueados esperando algo que no llega.

**Qué la dispara**

```promql
jvm_threads_live{job="mainvet/vetsoftware"}
```

con umbral `> 200` y `for: 10m`. Sin agregación: la expresión devuelve la serie tal
cual, así que hay **una instancia de alerta por serie** (en la práctica, una por
`service_version` presente).

El nombre de la métrica es `jvm_threads_live`, **sin** el sufijo `_threads` que aparece
en el scrape local del actuator. El comentario del propio archivo de reglas
(`observability/grafana-managed/vetsoftware-platform-alerts-managed.yml:263-264`) lo
advierte. Verificado en la señal real.

`for: 10m` descarta el pico de arranque, que es real: Spring, Liquibase y los pools se
crean casi a la vez.

**Valores reales medidos en dev el 2026-08-19**: entre **29 y 35** hilos, estable a lo
largo de 24 h y de tres versiones distintas.

**Primero mirar**

1. **La serie en 6 h** — ¿es un escalón o un crecimiento monótono?

   ```promql
   jvm_threads_live{job="mainvet/vetsoftware"}
   deriv(jvm_threads_live{job="mainvet/vetsoftware"}[1h])
   ```

   Una derivada positiva y constante es fuga de hilos: no se va a estabilizar sola.
2. **Por estado** — dice si están trabajando o esperando:

   ```promql
   jvm_threads_states{job="mainvet/vetsoftware"}
   ```

   `BLOCKED` alto = contención de lock (mira el defecto del appender más abajo).
   `WAITING`/`TIMED_WAITING` alto = esperando E/S o una conexión.
3. **¿Están esperando la base de datos?**

   ```promql
   hikaricp_connections_pending{job="mainvet/vetsoftware"}
   hikaricp_connections_active{job="mainvet/vetsoftware"}
   ```

   Es la causa más frecuente: los hilos de request se apilan esperando conexión.
4. **¿Hay peticiones en vuelo acumulándose?**

   ```promql
   sum(http_server_requests_active_milliseconds_count{job="mainvet/vetsoftware"})
   ```

   Ojo: esta serie llega con `uri="UNKNOWN"` (el temporizador de larga duración no
   conoce la ruta mientras la petición está en vuelo). **Sirve como contador global de
   concurrencia, no para saber qué endpoint.**
5. **Volumen HTTP del mismo intervalo**:
   `sum(rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware"}[5m]))`.
   Si el tráfico no subió y los hilos sí, no es carga: es fuga o bloqueo.
6. **Los logs, buscando el síntoma terminal**:

   ```logql
   {service_name="vetsoftware", deployment_environment_name="dev"} |= "unable to create native thread"
   ```

**Causas habituales**

1. **Hilos de request bloqueados** esperando la base de datos o un proveedor externo sin
   timeout. Tomcat sigue aceptando y creando hilos hasta su máximo.
2. **Executor propio sin cota** — un `ThreadPoolExecutor` con cola ilimitada o
   `Executors.newCachedThreadPool()`.
3. **Cliente HTTP que crea recursos por llamada** en vez de reutilizar el pool.
4. **Fuga de scheduler** — tareas que no terminan y se acumulan.

**Qué hacer**

*Mitigación inmediata* — reiniciar la tarea (despliegue forzado) devuelve el conteo a la
línea base y no arregla nada. Antes de hacerlo, captura los pasos 2 y 3: son la única
evidencia y un reinicio la borra.

*Arreglo de fondo* — depende de la causa, pero el patrón es siempre el mismo: **poner
cota**. Timeout en el cliente que bloquea, tamaño máximo en el executor, cola acotada
con política de rechazo explícita (y su contador). Un descarte medido es operable; uno
invisible, no.

**Cuándo NO es un incidente**

- **El pico de arranque**, cubierto por el `for: 10m` y por los 180 s de `startPeriod`.
- **Durante un despliegue rodante**, mientras conviven dos tareas — aunque como la
  expresión no agrega, cada JVM se evalúa por separado y esto no debería sumar.
- Con la línea base real (29–35) esta alerta está a **seis veces** el valor observado:
  si suena, no es ruido.

**Defectos conocidos de la señal**

- **El umbral coincide con el máximo por defecto del pool de Tomcat.**
  `server.tomcat.threads.max` no está sobrescrito en el repo, así que vale 200. Si lo
  que crece son hilos de request, **para cuando `jvm_threads_live` supere 200 el pool ya
  está agotado y hay peticiones encoladas**: la alerta llega después del daño, no antes.
  Es un detector de catástrofe, no de degradación.
- **No hay indicador adelantado, porque el binder de Tomcat no se exporta.** Verificado:
  en Grafana Cloud existen `tomcat_sessions_*` pero **ninguna serie `tomcat_threads_*`**.
  El único proxy disponible es el paso 4 (`http_server_requests_active_*`), que llega con
  `uri="UNKNOWN"`. Arreglo: habilitar el binder de Tomcat (cuesta ~4 series) y alertar
  sobre `tomcat_threads_busy / tomcat_threads_config_max > 0.8`, que sí avisa antes.
- **Umbral absoluto sobre una línea base seis veces menor.** Criterio: con 29–35 hilos
  estables, un umbral en torno a **80** daría margen de reacción real y seguiría sin
  producir falsos positivos. 200 solo suena cuando el sistema ya está roto.
- **TEL-17 — el estado `BLOCKED` puede ser el propio logging.**
  `RedactingAppender` extiende `AppenderBase`, cuyo `doAppend` es `synchronized`
  (`VetSoftware/src/main/java/com/vetsoftware/app/infrastructure/logging/RedactingAppender.java:50`).
  En una tormenta de errores todos los hilos de request se serializan en ese lock y
  aparecen como `BLOCKED`. Si el paso 2 muestra `BLOCKED` alto **a la vez** que un pico
  de volumen de logs, mira ahí antes que al código de negocio.
- **`instance`/`service_instance_id` no identifican la tarea** (constante
  `ecs-fargate-spot`, contra OTel semconv). Ver el detalle en `VetSoftwareJvmHeapHigh`.
- **Sin prueba automática** (TEL-30).

---

### VetSoftwareProcessCpuHigh

**Qué significa** — El proceso Java lleva diez minutos consumiendo más del 85 % de la
**cuota de CPU de la tarea**. Si es real, todo lo demás va a ir lento.

**Qué la dispara**

```promql
process_cpu_usage{job="mainvet/vetsoftware"} / (512 / 1024)
```

con umbral `> 0.85` y `for: 10m`. El gauge crudo es de Micrometer (`ProcessorMetrics`,
sobre `OperatingSystemMXBean.getProcessCpuLoad`): una fracción entre 0 y 1 **normalizada
por el número de procesadores que ve la JVM**, que aquí es `system_cpu_count = 1`
(verificado en la señal real).

**Por qué se divide** (corregido el 2026-08-19; antes se comparaba el gauge crudo contra
0,85 y la alerta **no podía disparar nunca**): la cuota real de la tarea es 0,5 vCPU,
pero Java redondea la cuota hacia arriba para `availableProcessors` —ceil(0,5) = 1— y
normaliza sobre 1. El proceso no puede consumir más de 0,5 s de CPU por segundo de
reloj, así que el techo del gauge crudo es **≈ 0,50**: pedirle 0,85 era pedirle que
superara su propio máximo. Dividiendo por `512 / 1024` = 0,5 el valor pasa a ser
**fracción de cuota**, `1,0` significa cuota agotada, y el 0,85 del umbral recupera su
significado literal.

**El `512` sale de `environments/dev/variables.tf` (`backend_cpu = 512`)** y está escrito
como fracción, no como `0.5`, para que se vea de dónde viene. Es acoplamiento explícito
entre el YAML de alertas y el de Terraform: **ninguna métrica publicada expone la cuota**,
así que el divisor no puede derivarse solo. Si alguien cambia `backend_cpu`, hay que
tocar la alerta. Y ojo: la fórmula `cpu/1024` solo vale mientras `backend_cpu` ≤ 1024;
con 1024 o más la JVM ve `availableProcessors` ≥ 1, el gauge ya viene normalizado sobre
la cuota completa y **el divisor pasa a ser 1**.

Sin agregación: una instancia de alerta por serie. `for: 10m` supera de sobra los 180 s
de `startPeriod`, así que un arranque normal —contexto de Spring, Liquibase, JIT— no la
dispara.

**Valores reales medidos en dev el 2026-08-19**: el gauge crudo se mueve entre **0,0003 y
0,0098** (0,06 %–2 % de la cuota) en régimen permanente. Al arrancar, las primeras
muestras llegan a **1,0** —artefacto de la primera medición, no consumo real— pero duran
poco: `count_over_time((process_cpu_usage > 0.42)[7d:1m])` da **1–3 minutos por versión
en siete días**, muy por debajo del `for: 10m`. Por eso la expresión usa el gauge crudo y
**no** un `avg_over_time`: se probó con `[10m]` y empeora, estira el pico a 5 minutos.

**Primero mirar**

1. **La serie en 6 h**: `process_cpu_usage{job="mainvet/vetsoftware"}` — ojo, en crudo,
   sin dividir: los valores que verás son la mitad de los de la alerta.
2. **¿Es el proceso Java o el resto de la tarea?**

   ```promql
   system_cpu_usage{job="mainvet/vetsoftware"}
   system_cpu_count{job="mainvet/vetsoftware"}
   ```

   y en CloudWatch, `CPUUtilization` del servicio ECS (alarmas `backend-high-cpu` al
   85 % y `backend-cpu-saturated` al 95 %). **Si ECS está alto y `process_cpu_usage`
   bajo, el consumo es del sidecar `cloudflared`, no del backend.**
3. **¿Es el GC?** Es la causa que más se confunde con "CPU alta":

   ```promql
   jvm_gc_overhead{job="mainvet/vetsoftware"}
   sum by (cause, action) (increase(jvm_gc_pause_milliseconds_sum{job="mainvet/vetsoftware"}[15m]))
   ```

   Con SerialGC sobre 1 CPU visible, un GC descontrolado **es** CPU al 100 %.
4. **¿Es tráfico?**
   `sum by (uri) (rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware"}[5m]))`.
   Con 10 peticiones por cada 5 minutos de línea base, casi nunca lo es.
5. **¿Es un job programado?**

   ```promql
   sum by (job_name, job_outcome) (increase(tasks_scheduled_execution_milliseconds_count{job="mainvet/vetsoftware"}[30m]))
   ```

   Generación de PDF/QR, reconciliación DIAN y purga de tokens son los candidatos.
6. **Correlación con latencia**: si `HttpP95/P99` están también en alerta, es el mismo
   incidente. Sobre 0,5 vCPU, CPU saturada y latencia son la misma cosa.
7. **Los logs del intervalo**, para ver qué estaba corriendo:

   ```logql
   {service_name="vetsoftware", deployment_environment_name="dev"} | json
   ```

**Causas habituales**

1. **GC en bucle** — mira el heap **antes** que el código. Es la causa número uno de CPU
   sostenida en una JVM.
2. **Job programado pesado** — reconciliación, PDF, informes. Sobre 0,5 vCPU cualquier
   trabajo por lotes se nota.
3. **Bucle o algoritmo patológico** en el código, normalmente estrenado en el último
   despliegue. Compruébalo con `service_version`.
4. **Arranque** — Spring + Liquibase + JIT. Filtrado por el `for: 10m`.
5. **Interrupción de Spot y rearranque** — la tarea corre 100 % en Fargate Spot
   (`fargate_spot_weight = 1`), así que los rearranques son un evento normal, no una
   anomalía.

**Qué hacer**

*Mitigación inmediata*

- Si es GC, ve a `VetSoftwareJvmHeapHigh` y trátalo como un problema de memoria.
- Si es un job, comprobar si puede posponerse; no hay palanca de throttling.
- Si es un despliegue reciente, revertir.
- **No** perfiles en caliente sobre 0,5 vCPU: el propio perfilador se lleva la CPU que
  queda.

*Arreglo de fondo*

- ~~Corregir el umbral~~ → hecho el 2026-08-19 normalizando por la cuota. Lo que queda
  abierto es el **acoplamiento manual** con `backend_cpu`: hoy nada impide que alguien
  cambie la cuota en Terraform y deje la alerta descalibrada en silencio. La forma
  robusta de cerrarlo es exportar la cuota como métrica (o pasarla en
  `OTEL_RESOURCE_ATTRIBUTES` y publicarla como gauge) para que la alerta la lea en vez de
  suponerla; mientras no exista, el comentario del YAML es toda la defensa que hay.
- Si el CPU real de la tarea es el cuello de botella, subir `backend_cpu` es una decisión
  de infraestructura con su propio coste; documentarla antes de aplicarla.

**Cuándo NO es un incidente**

- **Arranque y despliegue**: cubiertos por el `for: 10m` frente a los 180 s de
  `startPeriod`. Durante un despliegue rodante conviven dos tareas arrancando.
- Un job por lotes que corre y termina en menos de diez minutos.
- Con la línea base real (0,06 %–2 % de la cuota) cualquier valor por encima del 20 % ya
  sería un cambio de régimen que merece mirarse, mucho antes del 85 %.

**Defectos conocidos de la señal**

- ~~**El umbral es inalcanzable: la alerta no puede disparar nunca.**~~ → **CORREGIDO
  2026-08-19.** Queda documentado porque explica por qué esta alerta no aparece **ni una
  vez** en el historial anterior a esa fecha: no es que no hubiera picos de CPU, es que
  el umbral estaba por encima del techo de la métrica. Lo medido entonces, por dos vías
  independientes: (a) la tarea declara **512 unidades de CPU** en total
  (`environments/dev/variables.tf`, `backend_cpu = 512`) = **0,5 vCPU** de cuota cgroup
  para *toda* la tarea, de las que 64 son la reserva de `cloudflared`; (b) la JVM reporta
  `system_cpu_count = 1`, así que `process_cpu_usage` se normaliza sobre **una** CPU
  mientras el cgroup la limita a **media**. Techo del gauge ≈ 0,50 contra un umbral de
  0,85. El arreglo aplicado normaliza por la cuota en vez de bajar el umbral a un número
  suelto: así el 0,85 sigue significando «85 %» y quien lo lea no tiene que saberse la
  cuota de memoria.
- **`instance` y `service_instance_id` valen la constante `ecs-fargate-spot`**, no el ID
  de la tarea, contra `service.instance.id` de OTel semconv. Si dos tareas conviven, sus
  dos instancias de alerta son **indistinguibles** en el mensaje de Slack salvo por
  `service_version`. Mismo defecto en las cuatro alertas de runtime.
- **La CPU del sidecar es invisible desde aquí.** `process_cpu_usage` mide solo la JVM;
  `cloudflared` comparte la misma cuota de 0,5 vCPU y puede saturarla sin que esta
  alerta se entere. La contraparte es la alarma `backend-high-cpu` de CloudWatch, que
  mide la tarea completa. Son señales complementarias, no redundantes: usa las dos.
- **Solapamiento no coordinado con las alarmas de ECS.** `backend-high-cpu` (85 %,
  2 × 5 min) y `backend-cpu-saturated` (95 %, 3 × 5 min) miden lo mismo desde otro
  ángulo y hacia otro canal (SNS → Slack por Amazon Q, no el motor de Grafana). Desde el
  2026-08-19 al menos **los porcentajes son comparables**: esta alerta también mide
  contra la cuota de la tarea, así que un 85 % aquí y un 85 % allí hablan de lo mismo
  (antes no). Lo que sigue sin estar coordinado es la notificación: un incidente de CPU
  real produce mensajes desde dos sistemas distintos y ninguno menciona al otro.
- **Sin prueba automática** (TEL-30).

---

## 3. Base de datos y Valkey

### VetSoftwareDatabaseConnectionTimeouts

**Qué significa** — Una petición pidió una conexión a MySQL, esperó los 3 segundos que da el pool y se quedó sin ella. La operación del usuario ya falló: esto no es un aviso preventivo, es daño consumado. Es el primer síntoma que aparece cuando RDS se está cayendo, cuando la red al RDS se rompió, o cuando el código retiene conexiones sin devolverlas.

**Qué la dispara** —

```promql
increase(hikaricp_connections_timeout_total{job="mainvet/vetsoftware"}[5m])
```

con umbral `> 0` y `for: 1m`. Cualquier timeout en cinco minutos, uno solo, ya dispara. No hay guarda de volumen y es correcto que no la haya: HikariCP solo incrementa este contador cuando una petición real se quedó sin conexión tras agotar `connection-timeout` (3000 ms, `application.yml:67` del backend). Un solo evento significa una petición perdida.

El `for: 1m` es corto a propósito: la ventana `[5m]` del `increase` ya aporta toda la persistencia que hace falta, y esta es la alerta que debe llegar *antes* que `VetSoftwareDatabasePoolSaturated` (`for: 5m`). Efecto lateral que conviene conocer: el mismo `[5m]` mantiene la alerta encendida unos cinco minutos después del último timeout, aunque la base ya se haya recuperado. No la des por resuelta por el hecho de que siga en rojo un rato.

La expresión es multidimensional (sin `sum`), así que hay una instancia de alerta por `service_version`. Tras un despliegue puedes ver dos.

**Primero mirar** —

1. ¿La instancia RDS existe y está `available`? Esto va **primero que la red y primero que el código**, porque la base de dev tiene historial de caídas por memoria (seis `RDS-EVENT-0403` documentados en `docs/COSTS.md:42`, con el buffer pool de InnoDB reducido a 27 MiB y la instancia encadenando shutdown → recovery → restart hasta quedar `stopped`).

   ```bash
   aws rds describe-db-instances --db-instance-identifier vetsoftware-dev --query 'DBInstances[0].DBInstanceStatus'
   aws rds describe-events --source-identifier vetsoftware-dev --source-type db-instance --duration 120
   ```

   `describe-events` es obligatorio, no opcional: un arranque automático de RDS **no deja rastro en CloudTrail** (AWS reinicia sola toda instancia parada a los 7 días) y `describe-events` es el único sitio donde eso se ve.

2. ¿Llegaron antes las alarmas de CloudWatch de la §3 de `docs/ALERTAS_OPERATIVAS.md`? `database-low-memory`, `database-swap-usage`, `database-memory-exhausted`, `database-saturated`. Si alguna está en ALARM, la causa es RDS y no la aplicación: sigue por §3 y deja de mirar el pool.

3. Cuánto duele, y si el pool tuvo algo que ver:

   ```promql
   increase(hikaricp_connections_timeout_total{job="mainvet/vetsoftware"}[1h])
   hikaricp_connections_active{job="mainvet/vetsoftware"}
   hikaricp_connections_pending{job="mainvet/vetsoftware"}
   hikaricp_connections_idle{job="mainvet/vetsoftware"}
   ```

   Si `active` se quedó muy por debajo de 10 mientras había timeouts, **el pool no estaba lleno**: el problema es que crear la conexión falla (base caída, DNS, security group), no que sobre demanda. Confírmalo con el tiempo de creación:

   ```promql
   rate(hikaricp_connections_creation_milliseconds_sum{job="mainvet/vetsoftware"}[5m])
   / clamp_min(rate(hikaricp_connections_creation_milliseconds_count{job="mainvet/vetsoftware"}[5m]), 1)
   ```

4. El síntoma que ve el usuario. En dev ya se observó `status="500"` con `error="CannotCreateTransactionException"` en `/auth/login/system`: un fallo de conexión que sale por la puerta del login.

   ```promql
   sum by (uri, error) (rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",status="500"}[5m]))
   ```

   Si esto tiene volumen, `VetSoftwareHttp5xxRateHigh` va a sonar detrás. Es la misma causa, no un segundo incidente.

5. Los logs de la ventana, en Loki:

   ```logql
   {service_name="vetsoftware"} |= "CannotCreateTransaction"
   {service_name="vetsoftware"} |= "Connection is not available"
   {service_name="vetsoftware"} |= "Apparent connection leak"
   ```

   Lo último es la red de `leak-detection-threshold: 20000`: HikariCP delata cualquier conexión retenida más de 20 s. Si aparece, tienes el stacktrace del culpable y ya sabes qué arreglar.

**Causas habituales** — En orden de frecuencia real en este entorno:

1. **RDS no está**: parada por el apagado programado y alguien pegándole fuera de horario, o caída por memoria. Con diferencia la más común.
2. **RDS está pero asfixiada**: `database-saturated` en ALARM, CPU alta con memoria en el piso; las conexiones existentes van lentas y las nuevas no entran a tiempo.
3. **Conexiones retenidas por el código**: una llamada HTTP a un tercero (DIAN/MATIAS) dentro de una transacción. Es exactamente el caso que `leak-detection-threshold` fue puesto a cazar. La §7 de `docs/ALERTAS_OPERATIVAS.md` lo dice sin rodeos para `database-connections-exhausted`: «casi siempre conexiones sin devolver al pool, no carga».
4. **Pool corto de verdad**: 10 por tarea. Solo es plausible con tráfico real y `active` pegado a 10 — cosa que en dev nunca se ha visto (máximo observado en 7 días: 1).

**Qué hacer** —

*Mitigación inmediata.* Si RDS está `stopped` o en estado incompatible, arráncala con el workflow *Start dev environment*; si está `available` pero ahogada, la salida es la de §3 (subir clase de instancia, **no reiniciar a ciegas** — ante `RDS-EVENT-0031` RDS recomienda restaurar a un punto en el tiempo y reiniciar destruye el diagnóstico). Si el diagnóstico apunta a fugas y hay que aguantar hasta el arreglo, `DB_POOL_MAX` se sube por variable de entorno sin recompilar — pero es un parche que compra minutos y esconde la fuga; el comentario de `application.yml:55-62` explica por qué el techo no es la aplicación sino la base.

*Arreglo de fondo.* Sacar las llamadas remotas de dentro de las transacciones. Un pool de 10 con `connection-timeout` de 3 s está dimensionado para transacciones cortas; si una operación tarda más de 20 s con una conexión en la mano, el problema es el diseño de esa operación y ninguna cifra del pool lo arregla.

**Cuándo NO es un incidente** — Prácticamente nunca. Dos excepciones concretas:

- **Justo después del apagado programado** (ECS 20:00, RDS 20:15 hora de Bogotá, lunes a viernes). Si RDS se para a las 20:15 y por lo que sea el backend sigue vivo, los timeouts son el apagado, no una avería. Comprueba la hora antes de moverte.
- **Durante un `Start dev environment`**, si el backend arranca antes que la base.

Un timeout aislado en horario hábil **sí es un incidente**: alguien perdió una operación.

**Defectos conocidos de la señal** —

- **Ángulo muerto: si la base no está al arrancar, esta alerta no existe.** El backend no llega a publicar métricas y el contador nunca aparece; con `noDataState: OK` la regla queda en Normal mientras la aplicación está en crash loop. Ese caso lo cubren las alarmas de ECS (`ecs-task-failed`, `backend-crash-loop`) y la §2 de `docs/ALERTAS_OPERATIVAS.md`, no esta regla. No interpretes «verde aquí» como «la base responde».
- **Estas reglas Grafana-managed son el arreglo del hallazgo bloqueante TEL-01** de la auditoría de telemetría: las 37 alertas y 57 recording rules del repo solo evaluaban en el stack Docker local, contra `http_server_requests_seconds_*` y `job="vetsoftware"`, mientras a Grafana Cloud llega `_milliseconds_` con `job="mainvet/vetsoftware"`. Si copias una expresión de `docker/prometheus-*.yml` a este stack, **no va a devolver nada**: las unidades y el `job` son otros.
- **Sin prueba `promtool`.** Es deuda de TEL-30 extendida al plano cloud: las reglas Grafana-managed no tienen ningún gate automático que verifique sus expresiones. Una regresión en el PromQL de este fichero se descubre en el incidente.
- La anotación `runbook` de las cinco reglas de este bloque apunta a `docs/ALERTAMIENTO_OPERATIVO.md#<ancla>` (repo del backend). Este documento provee las anclas; si el fichero final se publica con otro nombre o en otro repo, hay que actualizar la anotación en los dos YAML o el enlace de Slack cae en el vacío.

---

### VetSoftwareDatabasePoolSaturated

**Qué significa** — Casi todas las conexiones a MySQL que la aplicación tiene reservadas están ocupadas, y llevan así cinco minutos. Todavía puede que nadie haya fallado, pero el margen se acabó: la siguiente ráfaga de tráfico se va a encolar y después a caer por timeout.

**Qué la dispara** —

```promql
hikaricp_connections_active{job="mainvet/vetsoftware"}
/
clamp_min(hikaricp_connections_max{job="mainvet/vetsoftware"}, 1)
```

con umbral `> 0.85` y `for: 5m`. El pool es de 10 (`DB_POOL_MAX:10`, `application.yml:63`), así que en la práctica **la alerta salta con 9 o 10 conexiones activas de 10**, sostenidas cinco minutos. El `clamp_min` solo evita la división por cero si el gauge llega en 0 durante el arranque; hoy `hikaricp_connections_max` vale 10 de forma estable.

La división es 1:1 por etiquetas comunes, `pool` incluida (`vetsoftware-hikari`), así que la relación se calcula por pool y no mezcla instancias.

El `for: 5m` es el punto clave: `active` es un *gauge* muestreado en cada exportación, no un promedio. Un pico de un segundo no aparece siquiera en la serie. Que cinco muestras consecutivas den ≥ 85 % significa saturación real y continuada, no una ráfaga.

**Primero mirar** —

1. ¿Hay ya peticiones esperando o cayendo? Estas dos respuestas ordenan todo lo demás:

   ```promql
   hikaricp_connections_pending{job="mainvet/vetsoftware"}
   increase(hikaricp_connections_timeout_total{job="mainvet/vetsoftware"}[5m])
   ```

   Con timeouts > 0 esto ya no es «margen agotado», es «usuarios perdiendo operaciones»: trátalo como `VetSoftwareDatabaseConnectionTimeouts`.

2. ¿Saturado por carga o por retención? La pregunta se contesta con el tiempo de uso, no con el conteo:

   ```promql
   rate(hikaricp_connections_usage_milliseconds_sum{job="mainvet/vetsoftware"}[5m])
   / clamp_min(rate(hikaricp_connections_usage_milliseconds_count{job="mainvet/vetsoftware"}[5m]), 1)
   ```

   ```promql
   hikaricp_connections_usage_max_milliseconds{job="mainvet/vetsoftware"}
   ```

   Un tiempo medio de uso de decenas de milisegundos con mucho tráfico es carga. Un tiempo medio de segundos, o un `usage_max` por encima de 20 s, es retención: transacciones largas o llamadas remotas dentro de la transacción.

3. Contrasta con el tráfico HTTP de la misma ventana. Si no subió, la saturación no viene de los usuarios:

   ```promql
   sum by (uri) (rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware"}[5m]))
   ```

4. Del lado del servidor, lo que dice §7 de `docs/ALERTAS_OPERATIVAS.md` para `database-connections-exhausted`: `SHOW PROCESSLIST` y buscar sesiones en `Sleep` con `Time` alto o en `Locked`.

5. Fugas declaradas por el propio HikariCP:

   ```logql
   {service_name="vetsoftware"} |= "Apparent connection leak detected"
   ```

**Causas habituales** —

1. **Conexiones retenidas más de lo debido**: transacción abierta mientras se llama a un tercero (DIAN/MATIAS), a S3, o mientras se genera un PDF. Es la causa número uno y la que documenta el propio `application.yml` al justificar `leak-detection-threshold: 20000`.
2. **Consulta lenta o bloqueo**: una sentencia sin índice o un lock de fila retiene su conexión hasta terminar; diez de esas y el pool está lleno.
3. **RDS lenta por presión de recursos**: si CPU o memoria de la instancia están al límite, todas las consultas tardan más y el pool se llena sin que haya cambiado nada en el código. Mira antes `database-high-cpu` y `database-low-memory`.
4. **Carga real**: la última candidata, no la primera. En dev el máximo de `hikaricp_connections_active` en los últimos 7 días fue **1**.

**Qué hacer** —

*Mitigación inmediata.* Si hay una consulta o transacción concreta atascada, mátala (`KILL <id>` sobre el proceso identificado en `SHOW PROCESSLIST`). Si el origen es un job programado en bucle, deshabilítalo. Subir `DB_POOL_MAX` es la última opción y hay que hacerla con la cuenta delante: el comentario de `application.yml:55-62` documenta que 10 por tarea sale de que prod escala a 4 tareas y `deployment_maximum_percent=200` permite 8 simultáneas durante un despliegue — a 30 por tarea serían 240 conexiones y **cada despliegue tumbaría la base**. Subir el pool sin recalcular ese producto cambia un incidente por otro peor.

*Arreglo de fondo.* Acortar la vida de la conexión, no ampliar el pool: sacar E/S remota de las transacciones, añadir el índice que falta, y usar `leak-detection-threshold` como criterio de aceptación de cada cambio en la capa de persistencia.

**Cuándo NO es un incidente** — No hay falso positivo conocido. Con un pool de 10 y un máximo histórico observado de 1 conexión activa, si esta alerta suena en dev **está pasando algo de verdad**. En prod, con 4 tareas de 10 conexiones cada una, un pico sostenido de 5 minutos en una sola tarea puede ser un desbalanceo del balanceador antes que un problema de base: compruébalo mirando si las demás tareas están igual.

**Defectos conocidos de la señal** —

- **Ciega a las ráfagas.** `hikaricp_connections_active` es un gauge muestreado en la exportación; una saturación de 30 segundos que provoque timeouts reales puede no dejar ni una muestra por encima de 0,85. Por eso la alerta de timeouts es la crítica de detección rápida y esta es la de tendencia — y por eso no debes concluir «el pool estaba bien» a partir de esta serie cuando hubo timeouts.
- **El p99 del panel no te lleva a una traza.** Hallazgo **TEL-28** de la auditoría: los exemplars sí se están emitiendo, pero el datasource de Grafana Cloud espera `traceID` y lo que llega es `trace_id`, así que el clic de «ver traza de ejemplo» no existe. Reconstruir la petición lenta exige buscarla a mano en Tempo por ventana temporal. El arreglo es un ticket a Soporte de Grafana Cloud para corregir `exemplarTraceIdDestinations` (el datasource está provisionado y `readOnly`); lo ejecuta el dueño de la cuenta.

---

### VetSoftwareDatabaseConnectionPending

**Qué significa** — Hay hilos haciendo cola para conseguir una conexión a la base. Todavía la consiguen —si no, sonaría la de timeouts—, pero están esperando, y esa espera se le suma entera al tiempo de respuesta del usuario. Es el aviso temprano: la degradación ya se nota, el fallo aún no ha llegado.

**Qué la dispara** —

```promql
hikaricp_connections_pending{job="mainvet/vetsoftware"}
```

con umbral `> 0` y `for: 3m`. Es decir: **al menos un hilo esperando en tres muestreos consecutivos**.

El detalle que la hace legítima pese al umbral de cero: `connection-timeout` son 3000 ms, así que ningún hilo puede figurar como pendiente más de 3 segundos. Que el gauge salga distinto de cero en tres muestras separadas un minuto no significa «alguien lleva 3 minutos esperando», significa **«en cada instante que miramos había alguien en la cola»** — o sea, congestión continua y no un pico. Ese razonamiento es lo que justifica que `> 0` no sea un umbral ingenuo aquí, y por qué el `for: 3m` no puede bajarse a 1m sin llenarlo de ruido.

Es `warning` y no `critical` porque hay recuperación real: el hilo acaba consiguiendo la conexión. Cuando deja de conseguirla, el que suena es `VetSoftwareDatabaseConnectionTimeouts` con severidad crítica.

**Primero mirar** —

1. Si esta alerta llegó **acompañada** de `VetSoftwareDatabasePoolSaturated` o de la de timeouts, ignora esta sección y trabaja la crítica: es el mismo incidente en una fase más avanzada.
2. Si llegó **sola**, la pregunta es cuánto falta para que sea grave:

   ```promql
   hikaricp_connections_active{job="mainvet/vetsoftware"}
   / clamp_min(hikaricp_connections_max{job="mainvet/vetsoftware"}, 1)
   ```

   Si hay pendientes con el pool lejos del 85 %, no es saturación: es que **crear** una conexión nueva está tardando (el pool arranca en `minimum-idle: 5` y expande bajo demanda).

   ```promql
   rate(hikaricp_connections_creation_milliseconds_sum{job="mainvet/vetsoftware"}[5m])
   / clamp_min(rate(hikaricp_connections_creation_milliseconds_count{job="mainvet/vetsoftware"}[5m]), 1)
   ```

   Un tiempo de creación alto apunta a la red o a la propia RDS, no al tamaño del pool. Handshake TLS, resolución DNS, o una instancia con la CPU en el techo.

3. Cuánto le cuesta al usuario esa espera:

   ```promql
   hikaricp_connections_acquire_max_milliseconds{job="mainvet/vetsoftware"}
   ```

   ```promql
   rate(hikaricp_connections_acquire_milliseconds_sum{job="mainvet/vetsoftware"}[5m])
   / clamp_min(rate(hikaricp_connections_acquire_milliseconds_count{job="mainvet/vetsoftware"}[5m]), 1)
   ```

   Este es el número que enseñar a quien pregunte «¿por qué va lento?». Si se acerca a los 3000 ms, los timeouts están a la vuelta de la esquina.

4. Créditos de ráfaga de la instancia, que degradan sin producir ningún error: `CPUCreditBalance`, `EBSIOBalance%` y `EBSByteBalance%` en CloudWatch. La §3 de `docs/ALERTAS_OPERATIVAS.md` lo describe exacto: agotarlos no genera error alguno, el throughput cae a la línea base y «la base de repente está lenta» sin explicación en ninguna métrica clásica. Ojo con `database-cpu-credits-low`: usa `treat_missing_data = ignore` porque parar una instancia de clase `t` borra el saldo, así que su OK no siempre es un OK real.

**Causas habituales** —

1. **Consultas más lentas de lo normal** por presión en RDS (CPU, memoria, créditos EBS agotados). Nada cambió en el código y aun así hay cola.
2. **Expansión del pool bajo carga**: al pasar de 5 conexiones ociosas a más, la creación de las nuevas hace esperar a los primeros. Transitorio y benigno, pero si se sostiene 3 minutos ya no es la expansión.
3. **Retención de conexiones** en tareas largas: misma causa raíz que `VetSoftwareDatabasePoolSaturated`, un escalón antes.
4. **Un job programado** ejecutándose a la vez que el tráfico interactivo y compitiendo por el mismo pool.

**Qué hacer** —

*Mitigación inmediata.* Normalmente ninguna. Esta alerta pide *vigilar*, no *actuar*: mira si escala hacia la de saturación o la de timeouts en los siguientes minutos. Si va escalando, aplica lo de esas dos secciones. Si el causante es un job puntual, espera a que termine.

*Arreglo de fondo.* Si se repite en horas concretas, hay una tarea que compite con el tráfico: sepárala en el tiempo o dale su propio pool. Si viene acompañada de un tiempo de creación alto de forma estable, el problema es la instancia RDS (clase o créditos) y la salida es §3 de `docs/ALERTAS_OPERATIVAS.md`, no el pool.

**Cuándo NO es un incidente** —

- **Arranque del backend**, cuando el pool aún se está poblando y `minimum-idle` no se ha alcanzado. Si la alerta aparece en los primeros minutos tras un despliegue o tras *Start dev environment*, dale otro ciclo antes de investigar.
- **Un job pesado y conocido** corriendo. La cola es real y el efecto también, pero es el coste esperado del job, no una avería.

**Defectos conocidos de la señal** —

- Con `warning` como severidad, esta alerta va al canal normal de Slack y **no hay aviso de resuelto**: las notificaciones de recuperación están desactivadas. El estado real solo se ve en *Alerting → Alert rules* del stack. No supongas que sigue activa porque el mensaje siga en el canal.
- La correlación log→traza dentro del stack local está rota (**TEL-27**): el *derived field* del datasource de Loki en `docker/grafana/provisioning/datasources/datasources.yml:24-29` busca `"traceId":"..."` y lo que se emite es `trace_id`. En el stack de Grafana Cloud sí se puede filtrar por `trace_id` a mano, pero el salto de un clic no funciona en local. Y en Loki de dev los logs no llevan `service_version` (**TEL-37**), así que responder «¿esto empezó con el último despliegue?» exige triangular por hora contra las métricas, que sí lo llevan.

---

### VetSoftwareValkeyCommandsFailing

**Qué significa** — El cliente Lettuce está recibiendo errores al hablar con Valkey (ElastiCache Serverless). Valkey sostiene dos cosas que importan: la caché de permisos y el rate limiting de login de bucket4j. Con Valkey degradado, **el freno de fuerza bruta del login deja de ser fiable y no hay ninguna otra señal que lo sustituya**.

**Qué la dispara** —

```promql
sum(rate(lettuce_milliseconds_count{job="mainvet/vetsoftware",error!="none"}[5m]))
```

con umbral `> 0` y `for: 5m`. Cualquier comando con error sostenido durante cinco minutos.

Dos decisiones deliberadas en esta expresión:

- **Sin `by (error)`**: una tormenta de excepciones de tipos distintos no debe partirse en cinco instancias de alerta y cinco mensajes en Slack.
- **Sin guarda de volumen**, a diferencia de las alertas HTTP. Aquí es correcto: el tráfico a Valkey en dev es ínfimo (≈ 45 comandos en 7 días, medido) y una tasa relativa con ese denominador no significaría nada. Lo que se vigila es la **presencia** de errores, no su proporción.

Efecto del `for: 5m` que conviene entender antes de que suene: un único comando fallido eleva la `rate[5m]` durante exactamente esa ventana de 5 minutos, así que un error aislado queda **justo en el borde** de disparar y lo normal es que no llegue. Dos errores separados en el tiempo sí disparan. En la práctica el `for` está haciendo de guarda de volumen.

El tag `error` lo pone el `DefaultMeterObservationHandler` de Micrometer a partir de la observación de Lettuce, que se registra en `CacheConfig.java:20-23` (`new MicrometerTracing(observationRegistry, "Redis")` sobre el `ClientResources` compartido por la caché y por bucket4j).

**Primero mirar** —

1. Qué error es, y sobre qué comando. Esta es la consulta que hay que ejecutar primero, y es la que la alerta agregada te está ocultando a propósito:

   ```promql
   sum by (error, db_operation) (increase(lettuce_milliseconds_count{job="mainvet/vetsoftware",error!="none"}[30m]))
   ```

   El nombre de la clase de excepción está en `error` y el comando en `db_operation`. `EVAL` es bucket4j (rate limiting); `GET`/`UNLINK` son la caché de Spring; `HELLO` y `CLIENT` son el handshake de conexión.

2. Si `error` menciona `WRONGPASS` o autenticación, **no sigas por aquí**: es el fallo documentado en §4 de `docs/ALERTAS_OPERATIVAS.md`. Un apply cortado a la mitad deja el usuario de ElastiCache y el secreto de conexión con contraseñas distintas. La alarma de CloudWatch `cache-auth-failures` cubre el mismo hecho desde el otro lado, y **la salida es subir `valkey_password_version`**, que fuerza a reescribir usuario y secreto en el mismo apply.

3. Estado de ElastiCache en CloudWatch, en este orden: `cache-throttled` (≥ 1 comando rechazado, crítica), `cache-ecpu-high` (> 80 % de 1.000 ECPU/s, umbral efectivo 240.000 por periodo de 300 s) y `cache-storage-high` (> 80 % de 1 GB). Los límites de dev son bajos a propósito para fijar el coste, así que **tocarlos es plausible**.

4. Reparto de comandos y volumen, para saber si la caché está funcionando en absoluto:

   ```promql
   sum by (db_operation) (increase(lettuce_milliseconds_count{job="mainvet/vetsoftware"}[24h]))
   ```

5. Consecuencia en el usuario: si los errores son de `EVAL`, mira si el login está devolviendo 5xx.

   ```promql
   sum by (uri, status) (rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri=~"(/api/v1)?/auth/login/(employee|system)"}[5m]))
   ```

   Y comprueba si `VetSoftwareAuthFailureSpike` está activa: con el rate limiter degradado, un ataque de fuerza bruta no encuentra freno.

6. Endpoint real al que apunta el cliente. Viaja como etiqueta de la propia métrica, así que se lee sin entrar a la consola:

   ```promql
   count by (net_sock_peer_addr) (lettuce_milliseconds_count{job="mainvet/vetsoftware"})
   ```

   Hoy debe devolver `vetsoftware-dev-valkey-acaf7c.serverless.use1.cache.amazonaws.com`. Si devuelve otra cosa, o `localhost`, el `REDIS_URL` de la task definition está mal.

**Causas habituales** —

1. **Credenciales desincronizadas** tras un apply parcial (`WRONGPASS`). El caso documentado y el más probable después de tocar infraestructura.
2. **`REDIS_URL` apuntando a un endpoint que ya no existe.** ElastiCache Serverless no se puede parar, así que si alguien lo recreó para ahorrar coste, el endpoint cambió y **la rotura es silenciosa**: nada avisa de que la URL quedó obsoleta.
3. **Límites de dev alcanzados**: 1 GB de almacenamiento o 1.000 ECPU/s. Se manifiesta como comandos rechazados (`cache-throttled`) antes que como errores del cliente.
4. **Red**: security group, subred o NAT tras un cambio de infraestructura.
5. **Timeout de comando** bajo latencia alta, en cuyo caso `VetSoftwareValkeyLatencyHigh` debería acompañar — **pero no podrá hasta que se despliegue el backend con los bordes del histograma**; comprueba el paso 1 de esa sección antes de deducir nada de su silencio.

**Qué hacer** —

*Mitigación inmediata.* Si es autenticación, subir `valkey_password_version` y aplicar. Si es endpoint, corregir `REDIS_URL` en la task definition y redesplegar. Si es límite de recursos, subir `valkey_maximum_data_storage_gb` o `valkey_maximum_ecpu_per_second`, sabiendo que son las palancas que fijan el coste (`docs/COSTS.md:153`).

*Arreglo de fondo.* Dos cosas, en este orden de importancia:

1. **Decidir el modo de fallo del rate limiter.** Hoy la conexión de bucket4j (`RateLimitConfig.rateLimitRedisConnection`) es un bean singleton creado al arrancar: si Valkey no está disponible al inicio, **la aplicación no arranca**. Eso es fallar cerrado en el arranque y fallar de forma no especificada en caliente. Esa decisión debe estar escrita, no ser un efecto colateral de la configuración de Spring.
2. **Contador propio de degradación de caché**, con `outcome` acotado, para poder distinguir «Valkey falló y seguimos» de «Valkey falló y perdimos el control de fuerza bruta». Hoy la única señal es el tag `error` de una métrica de instrumentación genérica.

**Cuándo NO es un incidente** —

- **Ventana de apagado programado**, 20:00–20:15 hora de Bogotá de lunes a viernes: ECS se apaga a las 20:00 y los cierres de conexión de esa parada podrían aparecer como comandos con error. **No verificado**: en 30 días la etiqueta `error` solo ha tomado el valor `none`, así que no hay una sola muestra de este comportamiento y no puedo afirmarlo. Si suena en esa franja, comprueba la hora antes de escalar.
- **Durante un despliegue**, por la misma razón.

Fuera de esas dos franjas, considéralo un incidente real.

**Defectos conocidos de la señal** —

- **Ángulo muerto: el fallo total de Valkey no dispara esta alerta.** Si Valkey no responde en el arranque, la aplicación muere antes de emitir una sola métrica de Lettuce; con `noDataState: OK` la regla se queda en Normal. El caso `WRONGPASS` de §4 de `docs/ALERTAS_OPERATIVAS.md` es exactamente ese: «el backend arranca y muere». Lo detectan `cache-auth-failures` y `ecs-task-failed` en CloudWatch, no esta regla. **Verde aquí no significa Valkey sano.**
- **Cardinalidad sin cota en `lettuce_*`.** Confirmado contra el stack: las series llevan `db_operation`, `db_system`, `error`, `net_sock_peer_addr`, `net_sock_peer_port`, `net_transport` más el recurso. Ninguna está acotada por el `MeterFilter` del backend, que solo cubre el prefijo `vetsoftware.business.` — es el punto (d) del hallazgo **TEL-18** y la misma familia que **TEL-04**. `error` toma el nombre de clase de cualquier excepción y `db_operation` el de cualquier comando Redis: una tormenta de errores heterogéneos multiplica series justo en el peor momento. Hoy son 6 valores de `db_operation` y 1 de `error`; en un incidente no hay techo declarado. Acotar `error` a un enum en un `MeterFilter` que cubra también `lettuce` es el arreglo.
- Relacionado, **TEL-04**: cuando el filtro de cardinalidad deniega un meter lo tira entero sin contador, sin log y sin test de paridad. Si algún día se extiende el filtro a `lettuce`, un valor nuevo desaparecería del panel sin que nadie se entere. El arreglo del filtro (contador `vetsoftware.observability.metrics.denied`) es previo a extenderlo.

---

### VetSoftwareValkeyLatencyHigh

**Qué significa** — Los comandos a Valkey están tardando más de lo aceptable. Valkey está en el camino caliente de la autorización: cada milisegundo suyo se le suma a cada petición del usuario.

> **Empieza por el paso 1 de «Primero mirar».** La expresión está corregida, pero los bordes del
> histograma llegan con una imagen del backend que a 2026-08-19 todavía no está desplegada:
> mientras `lettuce_milliseconds_bucket` publique un solo `le`, esta alerta no puede dispararse.

**Qué la dispara** —

```promql
histogram_quantile(
  0.99,
  sum by (le) (
    rate(lettuce_milliseconds_bucket{
      job="mainvet/vetsoftware",
      db_operation!~"CLIENT|HELLO|INFO|AUTH|COMMAND|SELECT|SUBSCRIBE|PING"
    }[5m])
  )
)
```

con umbral `> 50` (milisegundos, no segundos: en este stack los timers llegan en milisegundos vía OTLP) y `for: 10m`. Diez minutos porque una latencia alta de caché es tolerable en ráfaga y solo importa si se sostiene; es `warning` y no `critical` porque hay degradación, no fallo — los comandos siguen respondiendo.

**Por qué el filtro de `db_operation`: son dos poblaciones, no una.** Medido en dev: `CLIENT` y
`HELLO` tardan **60–77 ms** —son el saludo y la autenticación de una conexión nueva— frente a
**1–5 ms** de `GET`, `EVAL` y `UNLINK`, que son el trabajo real. Un p99 sobre la mezcla no
describe a ninguna de las dos poblaciones: en un sistema casi ocioso, donde cada ráfaga de uso
reabre conexiones, el establecimiento domina la estadística y empuja el cuantil por encima de
50 ms sin que nada esté roto. La alerta mide **el uso** de Valkey, no el coste de conectarse a él.

**El matcher es negativo a propósito.** Una lista blanca de operaciones de datos
(`db_operation=~"GET|EVAL|UNLINK|…"`) dejaría fuera **en silencio** cada comando nuevo que
introduzca la aplicación, y la alerta se iría apagando sola sin que nadie lo notara. Excluyendo,
lo desconocido entra y como mucho sobra ruido: falla del lado seguro. Si aparece otra operación
de protocolo, se añade a la exclusión **con la medición delante**, no por parecido de nombre.

**Primero mirar** —

1. **Antes que nada, comprueba que los bordes están desplegados.**

   ```promql
   count by (le) (count_over_time(lettuce_milliseconds_bucket{job="mainvet/vetsoftware"}[24h]))
   ```

   Esperado tras el despliegue: `1, 5, 25, 50, 100, +Inf`. **Si el único `le` que devuelve es `+Inf` —que es lo que devuelve hoy, verificado el 2026-08-19— la imagen con los bordes aún no está en dev**: `histogram_quantile` sigue dando `NaN`, esta alerta no puede haber disparado y lo que sospechas hay que medirlo a mano con el paso 4. Ventana de 24 h y no consulta instantánea: con el apagado nocturno de dev, lo instantáneo devuelve vacío y se confunde «no hay bordes» con «no hay backend».

2. **Desglosa por comando antes de creerte el p99.** Es el triaje que la agregación por `le` te oculta y lo primero que separa las dos poblaciones:

   ```promql
   histogram_quantile(
     0.99,
     sum by (le, db_operation) (rate(lettuce_milliseconds_bucket{job="mainvet/vetsoftware"}[30m]))
   )
   ```

   Si lo que sube es `GET`, `EVAL` o `UNLINK`, es Valkey o la red y sigue leyendo. Si lo que sube es `CLIENT`/`HELLO` —que la expresión de la alerta excluye, así que no fueron ellos quienes la dispararon— lo que tienes es reciclado de conexiones, no latencia de caché. **Esta consulta necesita los bordes del paso 1**; mientras no estén, su equivalente es el paso 4, que sí funciona hoy.

3. Estado de ElastiCache en CloudWatch: `cache-ecpu-high` (> 80 % de 1.000 ECPU/s) y `cache-storage-high` (> 80 % de 1 GB). Los límites de dev son deliberadamente bajos.

4. Latencia real, con las series que **sí** existen hoy sin depender de ningún bucket. Media por comando:

   ```promql
   sum by (db_operation) (rate(lettuce_milliseconds_sum{job="mainvet/vetsoftware"}[5m]))
   / clamp_min(sum by (db_operation) (rate(lettuce_milliseconds_count{job="mainvet/vetsoftware"}[5m])), 1)
   ```

   Y el peor caso reciente, que Micrometer sí publica como gauge:

   ```promql
   max by (db_operation) (lettuce_max_milliseconds{job="mainvet/vetsoftware"})
   ```

   Referencia medida en dev para calibrar: `CLIENT` y `HELLO` llegan a 60–77 ms, mientras `GET`, `EVAL` y `UNLINK` se quedan en 1–5 ms. Es la diferencia entre establecer la conexión y usarla, y es exactamente la separación que la expresión de la alerta ya hace por ti.

5. ¿Se traduce en latencia de usuario? Si no, no es urgente:

   ```promql
   histogram_quantile(0.99, sum by (le) (rate(http_server_requests_milliseconds_bucket{job="mainvet/vetsoftware"}[5m])))
   ```

**Causas habituales** —

1. **ECPU cerca del límite de 1.000/s**: ElastiCache Serverless empieza a encolar y la latencia sube antes de que aparezca ningún rechazo.
2. **Almacenamiento cerca de 1 GB con evictions**: cada eviction es trabajo extra y cada fallo de caché es un viaje a MySQL.
3. **Valores grandes en caché**: la serialización JSON de un objeto voluminoso hace lento un `GET` sin que Valkey tenga la culpa.
4. **Red o handshake**: si lo lento son solo `CLIENT`/`HELLO`, no es Valkey procesando, es el coste de abrir conexión. **Esa población ya no entra en la expresión**, así que si esta alerta ha disparado, el handshake no es la causa — pero sigue siendo lo primero que verás en el desglose crudo del paso 2, y confundirlo con el síntoma es el error clásico aquí.

**Qué hacer** —

*Mitigación inmediata.* Si hay presión de ECPU o de almacenamiento, subir `valkey_maximum_ecpu_per_second` o `valkey_maximum_data_storage_gb` — con la advertencia de coste: son las dos palancas que fijan la factura de un recurso que ya cuesta ~USD 6/mes de suelo con tráfico prácticamente nulo, y **ElastiCache Serverless no se puede parar**. Si la latencia viene de valores grandes, reducir el TTL o lo que se cachea (`RedisCacheConfiguration` con `entryTtl` de 5 minutos, `CacheConfig.java:27`).

*Arreglo de fondo.* Ya está escrito y solo le falta llegar a la señal: los bordes del histograma en el `application.yml` del backend. Mientras el paso 1 devuelva un único `le`, la vigilancia real de la latencia de Valkey no existe y lo único que hay es mirar a mano el paso 4. Ver defectos.

**Cuándo NO es un incidente** —

- **Con tráfico casi nulo, un p99 es una anécdota.** 45 comandos en 7 días significa que el percentil 99 lo decide un solo comando. La causa más frecuente de ese comando único —el `HELLO`/`CLIENT` de apertura de conexión, que legítimamente tarda decenas de milisegundos— **ya está fuera de la expresión**, pero el problema estadístico de fondo sigue: un solo `GET` lento marca el p99 de toda la ventana. **Desglosa por `db_operation` (paso 2) antes de creerte nada**: `GET` por encima de 50 ms sí es anómalo, y con este filtro es lo único que puede haber disparado.
- La expresión no lleva guarda de volumen, así que nada impide que ese único comando lento sea toda la alerta.

**Defectos conocidos de la señal** —

- **~~La alerta no puede dispararse.~~ → CORREGIDO el 2026-08-19, en dos mitades, y la segunda todavía no ha llegado a la señal.** El defecto era este: `lettuce_milliseconds_bucket` publicaba un solo bucket, `le="+Inf"`. `histogram_quantile` necesita al menos dos bordes para interpolar; con uno devuelve `NaN`, y `NaN > 50` es falso siempre. Con `noDataState: OK` la regla vivía en Normal de forma permanente y daba una falsa sensación de que la latencia de Valkey estaba vigilada. Es el caso de libro de un umbral que no cae sobre ningún borde `le` publicado, en su versión extrema: **el indicador desaparece en silencio en vez de fallar de forma visible**. Publicar el borde va antes que el umbral.

  *Lo que se hizo*, en `VetSoftware/src/main/resources/application.yml`, clave `management.metrics.distribution.slo`:

  ```yaml
  lettuce: 1ms,5ms,25ms,50ms,100ms
  ```

  **Cinco bordes SLO y NO `percentiles-histogram: true`**, a propósito y con la medida delante. La opción booleana publica el histograma completo: medido en Grafana Cloud, `http_server_requests_milliseconds_bucket` tiene **74** valores de `le`. Activarla para `lettuce` serían del orden de **530 series** entre `lettuce` y `lettuce.active`, frente a las ~**50** que cuestan estos cinco bordes — y con ~45 comandos cada 7 días, esa resolución extra no responde ninguna pregunta que los cinco bordes no respondan. El plan admite 15.000 series activas y el uso medido ronda 1.150; por qué ese margen importa lo explica `VetSoftwareIngestionNearLimit`: al 100 % Grafana Cloud rechaza la ingesta y se pierde **toda** la telemetría, en silencio.

  *Por qué exactamente 100 ms, que es la parte no obvia y la que evita repetir el error.* No es holgura decorativa: **`histogram_quantile` devuelve el borde finito más alto cuando el cuantil cae en el bucket `+Inf`**. Si 50 ms fuese el techo, todo lo más lento caería en `+Inf`, el p99 valdría **siempre 50 exactos** y `> 50` seguiría siendo falso para siempre. Sería cambiar una alerta muerta por otra alerta muerta — y la segunda es peor que la primera, porque los buckets parecerían sanos y nadie volvería a sospechar de la señal. Los demás bordes: **50 ms** es el umbral de la alerta (un umbral que no coincide con un borde publicado obliga a interpolar y el indicador deja de ser una cuenta de eventos); **1 ms y 5 ms** dan resolución a `GET`/`EVAL`/`UNLINK`, medidos en 1–5 ms, cuyo p99 si no se interpolaría dentro de un bucket enorme; **25 ms** es el escalón entre esa población y la del saludo de conexión (`CLIENT`/`HELLO`, 60–77 ms medidos).

  *Efecto colateral aceptado*: `PropertiesMeterFilter` resuelve el nombre por jerarquía, así que los bordes se aplican también al `LongTaskTimer` `lettuce.active` (~25 series que nadie consulta). Evitarlo exigiría un `MeterFilter` en Java con su bean y su test para ahorrar 25 series de 15.000.

  *Lo que falta*: **desplegar una imagen del backend que lleve ese cambio.** A 2026-08-19 no está en `develop` del backend, y `count by (le) (count_over_time(lettuce_milliseconds_bucket{job="mainvet/vetsoftware"}[24h]))` devuelve solo `+Inf`. Hasta que devuelva `1, 5, 25, 50, 100, +Inf`, **esta alerta sigue sin poder dispararse** por muy corregida que esté su expresión. Comprueba eso (paso 1) y no la tabla de cabecera.

- **La cardinalidad de `lettuce_*` sigue sin acotar, y con bordes cuesta seis veces más.** Mismo defecto que en `VetSoftwareValkeyCommandsFailing` (TEL-18, punto d): el `MeterFilter` del backend solo cubre el prefijo `vetsoftware.business.`, así que `db_operation` toma el nombre de cualquier comando Redis y `error` el de cualquier clase de excepción. Hasta ahora, un valor nuevo de `db_operation` añadía 1 serie de bucket; con los cinco bordes añade **6**. En absoluto sigue siendo pequeño, pero el techo declarado no existe y el arreglo —acotar a un enum en un `MeterFilter` que cubra también `lettuce`— no ha cambiado.

- Vale para las dos alertas de Valkey y para las tres de base de datos: la anotación `runbook` apunta a este documento por **URL absoluta** de GitHub con `#<ancla>`, y el ancla es el encabezado de la sección en minúsculas. **Renombrar un encabezado rompe el enlace del mensaje de Slack** sin que nada falle ni avise: el clic simplemente aterriza en ninguna parte.

---

## 4. Jobs, correo, seguridad y coste

### VetSoftwareScheduledJobFailing

**Qué significa** — Un trabajo programado del backend (los que corren solos, sin nadie delante)
está terminando mal. Detrás de este nombre hay **dos reglas** con el mismo título: la de
advertencia dice «este job registra fallos»; la crítica dice «este job no ha acertado ni una vez».
Nadie va a reintentarlo por su cuenta: si el job no funciona, el trabajo se acumula en silencio.

**Qué la dispara** — Ambas viven en `observability/grafana-managed/vetsoftware-cloud-additions-managed.yml`,
grupo `vetsoftware-scheduled-jobs`, evaluación cada 1 m, y ambas con `for: 30m`.

*Advertencia* (`uid: vetsw-scheduled-job-failing-warning`, `severity=warning`):

```promql
sum by (job_name) (
  increase(tasks_scheduled_execution_milliseconds_count{job="mainvet/vetsoftware",job_name!="",job_outcome=~"failure|partial_failure|error"}[30m])
) > 0
```

Cualquier ejecución con resultado `failure`, `partial_failure` o `error` en la última media hora.
El umbral es `> 0` porque el contador de fallos **solo existe si alguna vez hubo un fallo**: no
hay línea base que superar.

*Crítica* (`uid: vetsw-scheduled-job-failing-critical`, `severity=critical`): al menos **dos**
ejecuciones fallidas en `[2h]`, **menos** los `job_name` que en esas 2 h hayan procesado bien
algún elemento (`success` o `partial_failure`):

```promql
(sum by (job_name) (increase(tasks_scheduled_execution_milliseconds_count{job="mainvet/vetsoftware",job_name!="",job_outcome=~"failure|error"}[2h])) >= 2)
unless
(sum by (job_name) (increase(tasks_scheduled_execution_milliseconds_count{job="mainvet/vetsoftware",job_name!="",job_outcome=~"success|partial_failure"}[2h])) > 0)
```

El `unless` con `> 0` del lado de los éxitos está escrito así a propósito: un `== 0` clásico no
casaría si la serie de éxitos **no existe**, y la alerta moriría en silencio justo en el fallo
total que debe cubrir.

**Las tres decisiones de esta expresión, porque las tres son contraintuitivas** (corregido el
19-08-2026; el detalle y las mediciones están en «Defectos conocidos de la señal»):

- **`no_work` no está en el lado excluido, y meterlo sería un error.** Parece el arreglo natural
  del falso positivo, pero `dian.pending.reconciliation` alterna `no_work` con `failure` en la
  misma ventana: excluir por `no_work` deja la alerta **muda** durante un fallo total real.
  `no_work` es neutro — ni prueba salud ni prueba fallo — y por eso no entra en ningún lado.
- **`partial_failure` está en el lado excluido de la crítica y en el lado de fallos de la
  advertencia.** No es incoherente: significa `0 < failures < attempted`, o sea que hubo éxitos.
  Contradice el «sin ningún éxito» de la crítica, pero es exactamente el fallo parcial que la
  advertencia debe ver.
- **El `>= 2` es una guarda de repetición, no de volumen.** Separa «falló un ciclo suelto» de
  «lleva horas sin acertar». No puede subirse a 3: `security.tokens.cleanup` solo ejecuta 2,02
  veces por cada 2 h, así que con `>= 3` un cleanup roto al 100 % nunca alcanzaría el umbral y la
  regla quedaría **ciega** para él.

**Solapamiento con la advertencia**: en un fallo total casan las dos, y es deliberado. La
notification policy agrupa por `(alertname, severity)` y enruta cada `severity` a un receptor
distinto, así que llega una notificación al canal de horario laboral y otra al de guardia. Es la
escalada idiomática, no un duplicado.

**El `for: 30m` combinado con la ventana `[30m]` tiene una consecuencia que conviene saber**: un
único fallo aislado mantiene la expresión en `> 0` durante exactamente 30 minutos y luego sale de
la ventana, así que **queda en el borde y normalmente no llega a madurar**. Para que esta alerta
notifique hacen falta fallos repetidos o sostenidos. Es deliberado — un ciclo fallido que el
siguiente recupera no es un incidente — pero significa que **la ausencia de esta alerta no prueba
que no haya habido ningún fallo**.

**Primero mirar**

1. Qué job y en qué proporción. Es la consulta que separa «uno falló» de «está todo caído»:

   ```promql
   sum by (job_name, job_outcome) (increase(tasks_scheduled_execution_milliseconds_count{job="mainvet/vetsoftware"}[2h]))
   ```

2. Traduce el `job_name` a la clase que lo ejecuta — es lo que necesitas para leer el código:

   | `job_name` | Clase | Ruta |
   |---|---|---|
   | `dian.pending.reconciliation` | `PendingReconciliationJob` | `VetSoftware/src/main/java/com/vetsoftware/app/electronicdocument/infrastructure/scheduling/PendingReconciliationJob.java` |
   | `dian.contingency.retry` | `ContingencyRetryJob` | `VetSoftware/src/main/java/com/vetsoftware/app/electronicdocument/infrastructure/scheduling/ContingencyRetryJob.java` |
   | `security.tokens.cleanup` | `TokenCleanupJob` | `VetSoftware/src/main/java/com/vetsoftware/app/infrastructure/token/TokenCleanupJob.java` |

   El enum de resultados es acotado y vive en `ScheduledJobTelemetry.Outcome`:
   `no_work` / `success` / `partial_failure` / `failure` / `error`. `failure` = todos los
   elementos intentados fallaron; `partial_failure` = algunos; `error` = el job lanzó excepción y
   ni siquiera pudo informar.

3. Ve a los logs de ese job en Loki y salta por `trace_id`. Cada ejecución tiene su traza:

   ```logql
   {service_name="vetsoftware"} |= "Reconciliación falló"
   ```

4. Si es un job DIAN, mira el trabajo pendiente antes de tocar nada:

   ```promql
   vetsoftware_business_dian_backlog_documents
   sum by (result) (increase(vetsoftware_business_dian_transmissions_total[24h]))
   ```

**El caso real, medido el 19-08-2026**: `dian.pending.reconciliation` acumula en 7 días
**64 ejecuciones `failure`, 64 `no_work` y cero `success`**. La causa raíz está en la §02 de la
auditoría de telemetría: el documento 44 falla de forma determinista en cada ciclo
(«Cannot coerce 'true' [Boolean] to Integer») y arrastra el lote entero; había 5 documentos en
backlog con más de una hora. Es un fallo **determinista**, no un blip: ningún ciclo posterior lo
va a recuperar solo.

**Causas habituales**

1. Un documento envenenado en el lote que falla igual en cada pasada y arrastra al resto (el caso
   vivo de `dian.pending.reconciliation`).
2. Configuración rota que hace fallar el 100 %: empresa sin proveedor DIAN configurado
   (`IllegalStateException`), token de MATIAS expirado, credencial revocada. Falla siempre, hasta
   que alguien cambie configuración.
3. Fallo transitorio del proveedor externo (timeout, 429, 5xx). Este sí se recupera solo, y por
   eso normalmente no madura el `for: 30m`.
4. Base de datos saturada o el lease de job (`DianJobLeasePort`) sin liberar tras una parada
   abrupta de la tarea Fargate.

**Qué hacer**

*Mitigación inmediata*: identifica el documento o elemento concreto que falla en el log del job y
**sácalo del lote** (marcarlo, moverlo de estado) para que el resto del trabajo pendiente avance.
Un job que falla en bucle sobre el mismo elemento bloquea a todos los demás. Si la causa es
credencial o configuración, arréglala: ningún reintento la va a resolver.

*Arreglo de fondo*: si el job es de dominio fiscal, el elemento agotado debe **marcarse para no
volver a arrendarlo** en vez de reaparecer en cada ciclo (TEL-06), y el `ERROR` debe emitirse una
sola vez en la transición a agotado, no en cada pasada.

**Cuándo NO es un incidente**

- **Advertencia sola, sin la crítica, y con `success` o `partial_failure` en la misma ventana**:
  es fallo parcial. Un lote donde algunos elementos fallan y otros pasan. Merece revisión en
  horario hábil, no de madrugada. Es exactamente lo que la crítica excluye por diseño.
- **Advertencia sola por un único ciclo fallido**: desde el 19-08-2026 la crítica exige dos
  ejecuciones fallidas, así que un fallo suelto solo produce advertencia. Si el siguiente ciclo
  sale bien, se resolvió solo y no hay nada que hacer.
- Justo después de un despliegue: el primer ciclo tras arrancar puede fallar por el lease del
  ciclo anterior. Si el siguiente ciclo sale `success`, se resolvió solo.
- En dev, cualquier disparo posterior a las 20:00 de Bogotá es residuo de la ventana anterior: el
  backend está apagado y las series no avanzan.

**Defectos conocidos de la señal**

- **~~`no_work` no cuenta como éxito en la regla crítica~~ → CORREGIDO el 19-08-2026, pero NO
  como estaba apuntado aquí.** Conviene leer entero el porqué, porque el arreglo que parecía
  obvio rompía la alerta.

  *El defecto*: el `unless` excluía únicamente `job_outcome="success"`. Un job cuyo estado normal
  sea «no había trabajo» nunca produce `success` — `security.tokens.cleanup` ejecuta cada hora y
  todas sus ejecuciones son `no_work` —, así que «ningún éxito en 2 horas» era su estado
  permanente y **un solo fallo aislado suyo disparaba un crítico** sobre un job sano.

  *El arreglo que estaba apuntado aquí y que NO debe aplicarse*: meter `no_work` en el lado
  excluido (`job_outcome=~"success|no_work"`). Se probó contra el stack a las 00:47:40Z del
  19-08-2026, con la reconciliación DIAN cayendo al 100 %:

  | Expresión | `dian.pending.reconciliation` |
  | --- | --- |
  | Anterior (`unless success > 0`) | **6,05** — dispara |
  | Con `no_work` en el lado excluido | **vacío — MUDA** |
  | Actual (`>= 2 unless success\|partial_failure > 0`) | **6,05** — dispara |

  La razón: `dian.pending.reconciliation` corre cada 10 min y produce ~6 `failure` **y** ~6
  `no_work` por cada 2 h, porque muchos ciclos no encuentran documentos pendientes. `no_work`
  **convive con el fallo total**: no es prueba de salud. Excluir por él habría silenciado el
  incidente real que la regla existe para cubrir.

  *El arreglo real*, dos cambios independientes: (1) el lado excluido pasa a
  `success|partial_failure` —los únicos resultados que prueban que algún elemento se procesó
  bien— y `no_work` queda fuera de ambos lados; (2) una guarda de repetición `>= 2` en el lado de
  los fallos, que es lo que de verdad mata el falso positivo, porque el problema de fondo no era
  `no_work` sino que la expresión no distinguía un ciclo fallido suelto de un fallo sostenido.
  El `2` está medido: un fallo aislado extrapola a ~1,0-1,1 y queda por debajo; el job más lento
  (`security.tokens.cleanup`, 2,02 ejecuciones/2 h) sigue alcanzando el umbral si se rompe del
  todo. Contra-prueba inyectando +1 fallo simulado a los tres jobs: solo sobrevive
  `dian.pending.reconciliation` (7,05); los otros dos caen en 1 y quedan filtrados.
- **Hay un `@Scheduled` que ninguna de las dos reglas ve.** En el stack existe una serie de
  `tasks_scheduled_execution_milliseconds_count` **sin `job_name` ni `job_outcome`** (≈1.954
  ejecuciones en 7 días): es `BusinessGaugeMetrics.refresh`, que no está envuelto en
  `ScheduledJobTelemetry` y además **se traga la excepción en su propio `catch`**, así que la
  observación del scheduler nunca la ve (TEL-15). Si el snapshot de métricas de negocio se
  congela, esta alerta no dirá nada; el sustituto parcial es
  `vetsoftware_business_metrics_snapshot_age_seconds`. Desde el 19-08-2026 esa serie queda
  **excluida explícitamente** con `job_name!=""` en las dos reglas: no casaba ya (no lleva
  `job_outcome`), pero el matcher garantiza que un cambio futuro en esa etiqueta no la cuele en
  el `sum by (job_name)` como `job_name=""` y produzca un aviso con el nombre del job en blanco.
  Excluirla **no** tapa nada: nunca estuvo cubierta.
- **El backlog fiscal muerto reporta «no hay trabajo» (TEL-06).** En `ContingencyRetryJob`, los
  documentos agotados que requieren reemisión manual se saltan **sin contar como intentados**: si
  todo el lote está agotado, `Outcome.from(0,0)` devuelve `NO_WORK`. Facturas fiscales muertas
  esperando intervención humana producen exactamente la misma señal que un sistema sano. Esta
  alerta **jamás** cubrirá ese modo de fallo tal como está.
- **El log al que te manda el paso 3 vale menos de lo que debería (TEL-20).** `PendingReconciliationJob:83`,
  `ContingencyRetryJob:99` y `DeliverElectronicDocumentService:86` registran `e.getMessage()` en
  vez del `Throwable`: la línea que vas a leer dice literalmente «Reconciliación falló para
  documento 4711: null», sin causa encadenada y sin stacktrace. Y el mismo `catch` mezcla el
  transitorio (timeout, `WARN` correcto) con el determinista (`IllegalStateException` de empresa
  sin proveedor DIAN, que falla el 100 % de los ciclos y debería ser `ERROR`).
- **Esta alerta no existió durante semanas (TEL-01, TEL-10).** La métrica se emitía correctamente
  y ninguna regla la consumía: las reglas declaradas usaban `_seconds_` con `job="vetsoftware"`
  (el registro local) mientras a Grafana Cloud llega `_milliseconds_` con
  `job="mainvet/vetsoftware"`. Si alguien vuelve a escribir una regla sobre estas métricas, la
  unidad es **milisegundos**.

---

### VetSoftwareEmailSendFailing

**Qué significa** — Los correos no están saliendo. Detrás de este nombre hay **dos reglas**: la de
advertencia dice «más del 10 % está fallando»; la crítica dice «no ha salido ni uno en media
hora». Importa más de lo que parece: el envío es *fire-and-forget* y **no hay reintento ni
outbox**, así que cada fallo es un correo perdido para siempre, aunque la petición HTTP del
usuario haya respondido 200. Por ese canal se activan cuentas nuevas y se recuperan contraseñas.

**Qué la dispara** — Ambas en `vetsoftware-cloud-additions-managed.yml`, grupo
`vetsoftware-email-delivery`, evaluación cada 1 m.

*Advertencia* (`uid: vetsw-email-send-failing-warning`, `for: 15m`): tasa de fallo > 10 % en 30 m,
**con guarda de volumen** de al menos 5 envíos:

```promql
(
  sum(increase(email_send_template_milliseconds_count{job="mainvet/vetsoftware",email_outcome="failure"}[30m]))
  / clamp_min(sum(increase(email_send_template_milliseconds_count{job="mainvet/vetsoftware"}[30m])), 1)
)
and
(sum(increase(email_send_template_milliseconds_count{job="mainvet/vetsoftware"}[30m])) >= 5)
```

La guarda `>= 5` está **dentro** de la expresión, no en el nodo de umbral: sin ella, un único
correo fallido con tráfico casi nulo daría 100 % de tasa y notificaría. Con menos de 5 envíos la
expresión devuelve vacío → NoData → OK.

*Crítica* (`uid: vetsw-email-send-failing-critical`, `for: 10m`): hay fallos y **ningún** éxito en
30 minutos.

```promql
sum(increase(email_send_template_milliseconds_count{job="mainvet/vetsoftware",email_outcome="failure"}[30m]))
unless
(sum(increase(email_send_template_milliseconds_count{job="mainvet/vetsoftware",email_outcome="success"}[30m])) > 0)
```

**Por qué la crítica espera menos (10 m) que la advertencia (15 m)**: «cero éxitos» es un fallo
determinista que no se va a recuperar solo — cuanto antes se sepa, menos correos se pierden. Una
tasa parcial sí puede ser un blip del proveedor, y merece esperar un poco más antes de despertar
a alguien.

**Primero mirar**

1. El desglose por resultado. Es lo primero porque distingue «el proveedor rechaza» de «ni
   siquiera lo intentamos»:

   ```promql
   sum by (email_outcome) (increase(email_send_template_milliseconds_count{job="mainvet/vetsoftware"}[1h]))
   ```

   Valores posibles, emitidos por `ResendEmailClient`
   (`VetSoftware/src/main/java/com/vetsoftware/app/infrastructure/email/ResendEmailClient.java`):
   `success`, `failure`, `invalid` (destinatario o `templateId` vacío), `misconfigured`
   (`RESEND_API_KEY` ausente), `skipped` (`vetsoftware.email.enabled=false`).

2. Qué error concreto devuelve el proveedor. La etiqueta `error` la pone `Observation.error()`
   dentro de `recordFailure`:

   ```promql
   sum by (error) (increase(email_send_template_milliseconds_count{job="mainvet/vetsoftware",email_outcome="failure"}[6h]))
   ```

   **Medido el 19-08-2026 en el stack: `error="Forbidden"`.** Es el 403 de Resend por dominio
   remitente no verificado.

3. El log con la respuesta literal del proveedor. `dispatch` sí vuelca el cuerpo de la respuesta
   en la rama de `RestClientResponseException`:

   ```logql
   {service_name="vetsoftware"} |= "No se pudo enviar el correo"
   ```

4. Si el paso 2 no da nada porque no hay ninguna serie `failure`, comprueba `misconfigured` y
   `skipped` del paso 1 — ver «Defectos conocidos».

**Causas habituales**

1. **Dominio remitente no verificado en Resend.** Es el caso vivo: Resend responde
   `403 — "The kefaro.tech domain is not verified"`, y lleva así desde hace más de 30 días en dev.
   El arreglo es verificar el dominio en Resend, no reintentar.
2. Clave `RESEND_API_KEY` ausente, rotada o sin permisos → outcome `misconfigured` (nótese: **no**
   `failure`).
3. `templateId` de la plantilla server-side de Resend no configurado → outcome `invalid`.
4. Rate limit (429) o caída del proveedor → transitorio, tasa parcial, la advertencia.

**Qué hacer**

*Mitigación inmediata*: comprueba el dominio y la clave en el panel de Resend, y verifica qué
`templateId` está configurado. Nada de lo que hagas en el backend recupera los correos ya
perdidos: **no hay cola ni reintento**, así que el primer paso operativo real es
**listar a quién hay que reenviarle a mano** (registros y recuperaciones de contraseña de la
ventana afectada) — la métrica te da el conteo, el log te da el destinatario.

*Arreglo de fondo, y es el que mueve la aguja*: **la entrega de correo necesita reintento u
outbox** (TEL-07, TEL-09, TEL-18, TEL-25). Hoy toda pérdida es terminal y esta alerta solo te
cuenta lo que ya perdiste. Mientras eso no exista, subir niveles de log o afinar el umbral es
cosmético.

**Cuándo NO es un incidente**

- Con menos de 5 envíos en 30 minutos la advertencia **no puede** dispararse: la guarda de volumen
  lo impide por diseño. Si ves fallos en el panel y ninguna alerta, es esto y está bien.
- Un pico aislado de 429 que se recupera en un par de minutos no llega a los 15 minutos del `for`.
- Con el correo deshabilitado a propósito (`vetsoftware.email.enabled=false`) el outcome es
  `skipped` y ninguna de las dos reglas dispara. Correcto — pero ver el defecto siguiente.

**Defectos conocidos de la señal**

- **Punto ciego duro: si falta la `RESEND_API_KEY`, ninguna de las dos reglas dispara.** En
  `ResendEmailClient.ready()` la ausencia de clave produce `recordOutcome("misconfigured")` y
  `return` — `dispatch` nunca se llama, así que **no hay ni un solo `failure`**. La crítica exige
  al menos un `failure`, la advertencia divide `failure` entre el total. El fallo más total
  posible del canal de correo es invisible para su propia alerta. Hace falta una regla sobre
  `email_outcome=~"misconfigured|invalid"`.
- **El denominador de la advertencia diluye la tasa.** `sum(increase(...{job=...}[30m]))` incluye
  `skipped`, `invalid` y `misconfigured`, que no son intentos de envío. Una ráfaga de `skipped`
  hunde la tasa de fallo por debajo del 10 % y calla la alerta justo cuando la configuración está
  rota. El denominador correcto es `email_outcome=~"success|failure"`.
- **La etiqueta `error` no está acotada (TEL-18) y es coste directo.** El `MeterFilter`
  (`BusinessMetricCardinalityFilter`) solo cubre el prefijo `vetsoftware.business.`; la familia
  `email.*` queda fuera de esa allowlist. Cada excepción nueva del proveedor crea una serie nueva
  sin que nadie lo revise. Está confirmado en vivo: hoy existe `error="Forbidden"`. Esto alimenta
  directamente a `VetSoftwareIngestionNearLimit`.
- **El log no distingue las dos poblaciones (TEL-18).** `ResendEmailClient:172-180` tiene un solo
  `catch` → `WARN` para todo: el 403 determinista que mata el 100 % de los envíos es
  indistinguible de un 429 transitorio. Además ninguna de las dos ramas pasa el `Throwable`, y el
  cuerpo del proveedor va sin truncar. Lo correcto es: determinista (401/403/422/400) → `ERROR`
  con throwable; transitorio (429/5xx/timeout) → `WARN`.
- **Esta alerta no existía (TEL-12).** Hasta esta conversión, `grep -i email` sobre los cuatro
  ficheros de reglas devolvía cero coincidencias: 30 días de fallo total sin ninguna vigilancia.

*Lo que sí funciona, para que no lo dudes a las 3 de la mañana*: el `emailTaskExecutor`
(`AsyncConfig:58-68`) lleva `ContextPropagatingTaskDecorator`, así que **el `trace_id` sobrevive
al salto a hilo virtual** y el span del envío cuelga de la traza de la petición original. El salto
log→traza en este camino está intacto.

---

### VetSoftwareAuthFailureSpike

**Qué significa** — Alguien está fallando credenciales en el login a un ritmo que no parece humano:
más de 30 rechazos por minuto sostenidos diez minutos. Puede ser fuerza bruta, enumeración de
códigos de empleado, o un cliente mal configurado en bucle. No es «el sistema falló»: el sistema
funcionó y rechazó, que es su trabajo.

**Qué la dispara** — `vetsoftware-cloud-additions-managed.yml`, grupo `vetsoftware-auth-abuse`,
`uid: vetsw-auth-failure-spike`, `severity=warning`, evaluación cada 1 m, `for: 10m`.

```promql
sum(rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri=~"(/api/v1)?/auth/login/(employee|system)",status=~"401|403"}[5m])) > 0.5
```

0,5 rechazos/segundo ≈ 30/minuto. Con el `for: 10m` eso son **unos 300 rechazos sostenidos** antes
de que notifique. El `for` largo es deliberado: un pico de un minuto es un usuario torpe o un
despliegue de front que reintenta; diez minutos sostenidos ya es un patrón.

El selector por `uri` está verificado contra dev: los 401/403 aparecen únicamente en
`/auth/login/employee` y `/auth/login/system` (comprobado de nuevo el 19-08-2026 — las dos únicas
combinaciones presentes son `401 · /auth/login/system` y `403 · /auth/login/employee`).

**Primero mirar**

1. Qué endpoint y qué código, para saber si es contraseña mala (401) o acceso denegado (403):

   ```promql
   sum by (uri, status) (rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri=~"(/api/v1)?/auth/login/(employee|system)",status=~"401|403"}[5m]))
   ```

2. Compara contra el tráfico legítimo del mismo endpoint. Si los éxitos también suben, es carga
   real con usuarios equivocándose; si solo suben los rechazos, es ataque o cliente en bucle:

   ```promql
   sum by (status) (rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",uri=~"(/api/v1)?/auth/login/(employee|system)"}[5m]))
   ```

3. **De dónde viene.** El canal AUDIT de Loki es el que responde esto, no las métricas:

   ```logql
   {service_name="vetsoftware"} | json | event="login_failure"
   ```

   Lo que buscas es `client.ip` y `user_agent.original`. Una sola IP con un solo user-agent es un
   script; cientos de IPs es distribuido y el bloqueo por IP no sirve.

4. Comprueba que el rate limiting sigue de pie antes de concluir nada. `bucket4j` se apoya en
   Valkey, y si Valkey está degradado el control de fuerza bruta **ya no es fiable**:

   ```promql
   sum(rate(lettuce_milliseconds_count{job="mainvet/vetsoftware",error!="none"}[5m]))
   ```

   Si esto es > 0, mira antes `VetSoftwareValkeyCommandsFailing`: son el mismo incidente.

5. Mira si el pico está siendo cortado antes de llegar al login. Si el atacante ya está limitado,
   el volumen aparece como 429 y **no** en esta alerta:

   ```promql
   sum by (uri) (rate(http_server_requests_milliseconds_count{job="mainvet/vetsoftware",status="429"}[5m]))
   ```

**Causas habituales**

1. Cliente mal configurado en bucle: un front con credenciales caducadas reintentando sin backoff,
   o una integración con la clave equivocada. Es la causa más frecuente y la más aburrida.
2. Enumeración de códigos de empleado: muchos 401 contra `/auth/login/employee` con identificadores
   distintos y todos fallando.
3. Fuerza bruta clásica sobre pocas cuentas: mismo identificador, muchas contraseñas.
4. Credential stuffing distribuido: muchas IPs, un intento por cuenta. Es el que menos se parece a
   un pico y el que más fácilmente pasa por debajo del umbral.

**Qué hacer**

*Mitigación inmediata*: si el paso 3 da una IP o un rango concreto, bloquéalo en el borde
(Cloudflare / WAF), no en la aplicación. Si es un cliente propio mal configurado, apágalo o
corrige su credencial. **Contrasta antes de bloquear**: bloquear la IP de salida de una clínica
deja fuera a todo su personal.

*Arreglo de fondo*: si el patrón se repite, el control es rate limiting por identidad además de
por IP, y bloqueo temporal de cuenta tras N intentos. La alerta no es el control; es el aviso de
que el control no está siendo suficiente.

**Cuándo NO es un incidente**

- **En dev esta alerta es prácticamente inalcanzable, y eso es información, no un defecto.** El
  volumen medido es de ~5 logins en 24 h y **2 rechazos en 3 días**; 0,5/s sostenidos 10 minutos
  exige ~300 rechazos. Si esta alerta suena en dev, no es ruido estadístico: alguien está
  golpeando de verdad. La expresión **no lleva guarda de volumen**, pero al ser un umbral de tasa
  **absoluta** (no una proporción) el denominador pequeño no puede producir falsos positivos —
  el riesgo del volumen bajo es el contrario: falsos negativos.
- Tras un despliegue del front que invalide sesiones, un pico corto de 401 es esperable. Si se
  apaga antes de diez minutos, no madura.
- Una prueba de carga o de seguridad autorizada. Anúnciala antes; no hay silenciamiento
  automático.

**Defectos conocidos de la señal**

- **El evento que describe el ataque de verdad llega enmascarado (TEL-02).**
  `AuditLogger.refreshTokenReuseDetected` emite `actor.id` y `seconds_since_revocation`, pero
  **ninguna de las dos claves está en la allowlist de `LogFieldPolicy`**, así que salen como `***`.
  Es el único evento del canal AUDIT que describe un robo de refresh token en curso, y su propio
  javadoc dice que `seconds_since_revocation` es exactamente lo que separa el robo de una carrera
  benigna. Consecuencia práctica: **no podrás escalar de «fuerza bruta» a «token robado» con el
  log**. Y la contra-prueba `AuditFieldsSurviveRedactionTest` cubre los otros 11 eventos y omite
  precisamente este.
- **`level=warn` no sirve para triar esto (TEL-32).** `AuditLogger.unauthenticated` y `AuthFilter`
  registran `WARN` por **cada access token expirado**, que es un evento rutinario del ciclo de
  refresh del front. El nivel está insensibilizado: filtra por `event=login_failure`, no por nivel.
- **Agrupar por `reason` fragmenta el mismo motivo (TEL-33).** `AuthFilter` y
  `GlobalExceptionHandler` mezclan vocabularios: texto humano («Token expired») y enums snake
  («authentication_failed»). Un `sum by (reason)` en Loki te dará dos filas para una sola causa.
- **La enumeración contra los endpoints de recuperación es invisible (TEL-36).**
  `RecoverEmployeeCodeService:46` y `RequestPasswordResetService:57` registran las sondas
  anti-enumeración como `INFO` sin contador ni evento AUDIT. Esta alerta solo mira
  `/auth/login/*`: un atacante que enumere códigos de empleado por el endpoint de recuperación
  **no aparece aquí ni en ningún otro sitio**. No hay tasa que graficar.
- **Las duraciones del rastro de auditoría usan `System.currentTimeMillis()` (TEL-31,
  `AuditFilter.java:101,108`).** Un ajuste NTP produce `http.durationMs` negativos o inflados. Si
  reconstruyes la secuencia de un ataque por tiempos, no te fíes de los deltas al milisegundo
  (ISO/IEC 27001 A.8.17).

---

### VetSoftwareSecurityTokenTableGrowth

**Qué significa** — Una de las tablas de tokens de seguridad (refresh, verificación de correo,
restablecimiento de contraseña) tiene más filas de las que debería y la purga automática no está
consiguiendo bajarla. Es una fuga lenta: no rompe nada hoy, pero degrada la base de datos y, en el
caso de los refresh tokens, alarga la ventana de exposición de credenciales vivas.

**Qué la dispara** — `observability/grafana-managed/vetsoftware-platform-alerts-managed.yml`,
grupo `vetsoftware-security-token-retention`, `uid: vetsw-security-token-table-growth`,
`severity=warning`, evaluación cada 1 m, `for: 30m`.

```promql
vetsoftware_security_tokens_rows{job="mainvet/vetsoftware"}
- on(job, instance, service_version) group_left()
max by (job, instance, service_version) (
  vetsoftware_security_tokens_growth_threshold{job="mainvet/vetsoftware"}
)
> 0
```

La comparación está escrita como **resta** en vez de como `>`: es equivalente
(`rows > threshold` ⟺ `rows - threshold > 0`), pero deja la regla en estado *Normal con valor*
cuando la tabla está sana en vez de alternar entre *Alerting* y *NoData*, y hace que `$value` en
la notificación sea el **exceso de filas** sobre el umbral, que es información útil. El
`group_left()` es obligatorio: el lado izquierdo tiene una serie por `token_type` y el umbral no
lleva esa etiqueta.

Las claves del join se corrigieron el **2026-08-19** (antes eran solo `(job, instance)`, ver
defectos). El arreglo tiene dos capas a propósito: **`service_version` en el `on(...)`** para que
cada versión se compare contra *su* umbral —correcto si una versión futura cambia
`growthWarningThreshold`—, y **`max by (...)` en el lado derecho** para garantizar cardinalidad 1
pase lo que pase con las etiquetas. La segunda capa no es redundante: sin ella, dos tareas de la
**misma** versión (`desired_count > 1`, o un reintento de despliegue sobre la misma etiqueta)
reproducirían el fallo por otra vía.

Los dos gauges los publica `TokenCleanupMetrics`
(`VetSoftware/src/main/java/com/vetsoftware/app/infrastructure/token/TokenCleanupMetrics.java`);
el umbral sale de la propiedad `growthWarningThreshold` de `TokenCleanupProperties`. **Medido el
19-08-2026 en dev: umbral 50.000; filas reales 0–2 por tipo.**

El `for: 30m` existe para no notificar por un pico entre purgas.

**Primero mirar**

1. Qué tabla y cuánto exceso:

   ```promql
   vetsoftware_security_tokens_rows{job="mainvet/vetsoftware"}
   vetsoftware_security_tokens_growth_threshold{job="mainvet/vetsoftware"}
   ```

2. **¿La purga está corriendo?** Es la pregunta central, y se responde con la métrica del job, no
   con la de filas:

   ```promql
   sum by (job_outcome) (increase(tasks_scheduled_execution_milliseconds_count{job="mainvet/vetsoftware",job_name="security.tokens.cleanup"}[6h]))
   ```

   Si no hay **ninguna** serie, el job no está corriendo: revisa
   `vetsoftware.token-cleanup.enabled` (por defecto activo, `matchIfMissing = true`).

3. ¿Está purgando pero no da abasto?

   ```promql
   sum by (token_type) (increase(vetsoftware_security_tokens_purged_total{job="mainvet/vetsoftware"}[6h]))
   ```

   Si `purged` avanza y `rows` no baja, el ritmo de creación supera al de purga. Mira
   `maxBatchesPerRun` × `batchSize` en `TokenCleanupProperties`: `TokenCleanupJob.drain()` corta
   tras `maxBatchesPerRun` lotes aunque quede trabajo, así que un backlog grande necesita varias
   ejecuciones para drenarse.

4. La línea de log que el propio job emite cuando lo detecta:

   ```logql
   {service_name="vetsoftware"} |= "Crecimiento anormal de tokens"
   ```

5. Si el `token_type` es `refresh`, cruza con la actividad de login: un crecimiento de refresh
   tokens sin crecimiento de logins es sospechoso.

**Causas habituales**

1. El job de purga no corre: propiedad deshabilitada, o la tarea arranca y muere antes del
   `initial-delay` de 5 minutos.
2. El job corre pero el drenaje está topado por `maxBatchesPerRun`: la tabla baja, pero más
   despacio de lo que sube.
3. Retención configurada demasiado larga para el volumen real (`vetsoftware.token-cleanup.retention`).
4. Un cliente en bucle pidiendo refresh sin cerrar sesión, o registros masivos que generan tokens
   de verificación que nadie consume.

**Qué hacer**

*Mitigación inmediata*: si la tabla está grande y el job corre, sube `maxBatchesPerRun` (o baja el
intervalo `vetsoftware.token-cleanup.interval`, por defecto `PT1H`) para que drene más rápido.
Purgar a mano por SQL es la última opción y hay que hacerla por lotes: un `DELETE` masivo sobre la
tabla de refresh tokens bloquea el login.

*Arreglo de fondo*: si la causa es ritmo de creación, el problema no es la purga sino quién crea
los tokens — un cliente sin reutilizar el refresh, o un endpoint de registro sin límite.

**Cuándo NO es un incidente**

- Justo después de una carga de datos o de una prueba de registro masivo. La purga corre cada hora
  y aplica la ventana de retención: espera un ciclo completo antes de intervenir.
- En dev el umbral es 50.000 y las filas reales están entre 0 y 2 (medido el 2026-08-19). Un
  crecimiento real en dev es prácticamente imposible: si esta alerta suena en dev, **mira primero
  si llegó en estado `Error`** — el join ya no puede duplicar series, pero un error de evaluación
  sigue notificándose con el texto de esta regla. La anotación `Error` de la notificación lo
  distingue en un vistazo.

**Defectos conocidos de la señal**

- ~~**El `join` se rompe en cada despliegue.**~~ → **CORREGIDO 2026-08-19.** Se documenta porque
  explica cualquier hueco de evaluación en el historial anterior a esa fecha. Las claves del join
  eran `(job, instance)`, pero `instance` es la constante `ecs-fargate-spot` — no identifica la
  tarea. Medido:

  ```promql
  max_over_time((count by (job, instance) (vetsoftware_security_tokens_growth_threshold))[7d:1m])  →  2
  ```

  Durante los despliegues rodantes había **dos series de umbral con el mismo `(job, instance)`**, y
  un `group_left()` con dos candidatos a la derecha aborta la evaluación. Reproducido en vivo contra
  `grafanacloud-prom`, error literal: *«found duplicate series for the match group
  {instance="ecs-fargate-spot", job="mainvet/vetsoftware"} on the right side of the operation at
  timestamp 2026-08-18T04:50:03.184Z: {… service_version="1.3.4-dev.2"} and
  {… service_version="1.3.7-dev.1"}»*. Con `execErrState: Error`, esa evaluación fallida notificaba
  a Slack un mensaje que llevaba el `summary` de esta regla y por tanto **hablaba de tokens cuando
  lo que había pasado es que la consulta no compiló**. Es el mismo defecto de clase que TEL-13 —que
  la conversión Grafana-managed sí resolvió para `token_type`— sobreviviendo por otra etiqueta.
  Verificado tras el arreglo sobre el mismo rango de 7 días donde la expresión anterior abortaba:
  devuelve 3 series (una por `token_type`) y 6 durante los solapes de despliegue, **sin error**.
- **`execErrState: Error` SE MANTIENE, y es una decisión, no un olvido.** Lo que hacía daño no era
  notificar los errores de evaluación: era notificarlos **en cada despliegue** con un texto que
  hablaba de tokens. Corregido el join, un error aquí solo puede significar que cambió el esquema
  de etiquetas de los dos gauges — raro, real y accionable. Las alternativas se descartaron por lo
  mismo: `OK` convierte una regla rota en una regla que **parece sana mientras no mide nada**
  (pérdida silenciosa, el peor resultado), y `KeepLast` hereda esa ceguera presentando además un
  estado viejo como si fuera fresco. Mitigación añadida: la `description` ahora avisa
  explícitamente de que **un estado de Error no habla de tokens** y remite a la anotación `Error`.
- **Falta la meta-alerta de fallos de evaluación.** La forma correcta de vigilar «mis reglas no
  evalúan» no es rule por rule: es **una sola** alerta sobre
  `grafana_alerting_rule_evaluation_failures_total`. No existe en el repo (verificado). Su sitio es
  `observability/grafana-managed/vetsoftware-cloud-additions-managed.yml`. Con ella puesta, el
  `execErrState` de todas las reglas podría revisarse en bloque; sin ella, ese `Error` es la única
  señal de que una regla dejó de funcionar.
- **CAUSA RAÍZ, no arreglada:** `service.instance.id` está fijado al literal `ecs-fargate-spot`, y
  las semantic conventions de OpenTelemetry exigen que sea **único por instancia** dentro de un
  mismo `service.namespace`/`service.name`. Mientras siga siendo una constante, ninguna alerta de
  este stack puede distinguir dos tareas y toda métrica por tarea se solapa en silencio. Corregirlo
  es del backend/colector (`OTEL_RESOURCE_ATTRIBUTES` con el ARN o el UUID de la tarea), no de este
  fichero ni del YAML de alertas.
- ~~**La descripción promete algo que el `for` no cumple.**~~ → **CORREGIDO 2026-08-19.** Decía
  «sigue por encima del umbral **después de varias ejecuciones de la purga**», pero `for: 30m`
  madura **dentro de un solo ciclo de purga** (intervalo por defecto `PT1H`). Se corrigió el texto
  en vez de subir el `for` a `2h`: el `for` es el amortiguador del pico entre purgas y alargarlo
  retrasa la detección de una fuga real sin comprar nada, porque la pregunta «¿la purga corre?» la
  responde la métrica del job — el paso 2 de *Primero mirar*, no el `for`.
- **Versión heredada rota en el stack local (TEL-13).** `VetSoftware/docker/prometheus-platform-alerts.yml:363-367`
  sigue teniendo `> on(job, instance)` **sin** `group_left`, que es un match many-to-one que falla
  en cada ciclo: allí la alerta nunca evalúa y `VetSoftwarePrometheusRuleEvaluationFailures`
  dispara en bucle. Si depuras contra el Docker local, esa es la explicación.

---

### VetSoftwareIngestionNearLimit

**Qué significa** — El stack de Grafana Cloud se está acercando al límite de series de métricas que
permite el plan. Importa porque **al llegar al 100 % Grafana Cloud rechaza la ingesta**: no se
degrada, no avisa dentro de la aplicación, simplemente deja de aceptar métricas. Se pierde
telemetría en silencio y con ella la capacidad de ver cualquier otro incidente — incluidas todas
las demás alertas, que se quedan sin datos que evaluar. Es la alerta que protege a las demás.

**Qué la dispara** — `observability/grafana-managed/vetsoftware-cost-guard.yml`, grupo
`vetsoftware-cost-guard`, `uid: vetsw-ingestion-near-limit`, `severity=warning`, evaluación cada
**5 m**, `for: 15m` (tres evaluaciones consecutivas).

```promql
last_over_time(grafanacloud_instance_active_series[1h])
  / on(id) group_left()
grafanacloud_instance_metrics_limits{limit_name="max_active_series_per_user"}
> 0.8
```

**Ojo con el datasource: es `grafanacloud-usage`, no `grafanacloud-prom`.** Las series de uso del
plan viven en **otro tenant** (el de facturación de Grafana), no en el nuestro. Por eso esta alerta
no puede vivir en el ruler de Mimir —que solo alcanza su propio tenant— y es la única del
inventario que nunca pudo estar allí.

La condición es una **razón contra el límite publicado**, no un número absoluto de series: así
sigue siendo correcta si algún día cambia el plan y el techo se mueve. El `last_over_time([1h])`
tampoco es adorno: `grafanacloud_instance_active_series` se publica de forma dispersa y una
consulta instantánea pelada devuelve vacío la mayor parte del tiempo — sin él, la regla viviría en
NoData.

**Estado medido el 19-08-2026**: límite **15.000**; uso actual **684 series (4,56 %)**; máximo de
los últimos 7 días **1.583 (10,6 %)**. El margen es amplio; el riesgo no es el crecimiento
vegetativo sino un salto de cardinalidad.

**Primero mirar**

1. Confirma la magnitud, en el datasource **`grafanacloud-usage`**:

   ```promql
   last_over_time(grafanacloud_instance_active_series[1h])
   grafanacloud_instance_metrics_limits{limit_name="max_active_series_per_user"}
   ```

2. Compara contra la línea base para saber si es un salto o una subida lenta:

   ```promql
   max_over_time(grafanacloud_instance_active_series[7d])
   ```

3. Ahora cambia al datasource **`grafanacloud-prom`** y busca qué familia creció:

   ```promql
   topk(10, count by (__name__)({__name__=~".+"}))
   ```

4. Ve directo a los sospechosos conocidos, que están fuera de la allowlist del `MeterFilter`:

   ```promql
   count by (error) (email_send_template_milliseconds_count)
   count by (error) (lettuce_milliseconds_count)
   ```

5. Y comprueba cuántas versiones conviven, porque **cada serie lleva `service_version`**:

   ```promql
   count by (service_version) (target_info)
   ```

**Causas habituales**

1. **Una etiqueta sin acotar en una métrica.** Es la causa dominante y la más cara.
   `BusinessMetricCardinalityFilter` **solo cubre el prefijo `vetsoftware.business.`**: las
   familias `email.*` y `lettuce.*` quedan fuera. La etiqueta `error` de `email.*` la pone
   `Observation.error()` con el nombre de la excepción del proveedor — una excepción nueva de
   Resend crea series nuevas sin que nadie lo revise (verificado: hoy existe `error="Forbidden"`).
2. **Rotación de `service_version` en los despliegues.** Cada versión desplegada duplica
   temporalmente todas las series hasta que las antiguas expiran. Medido: 3 versiones distintas en
   7 días (`1.3.7-dev.1`, `1.4.0-dev.1`, `1.4.1-dev.1`). El pico está siempre justo después de un
   despliegue.
3. **Activación de las recording rules de SLO**: añaden ~300 series de golpe.
4. Un identificador colado como etiqueta de métrica (`companyId`, `animalId`, número de factura).
   No ha pasado, pero es el fallo canónico y el que multiplica de verdad: series = producto
   cartesiano de los valores de todas las etiquetas.

**Qué hacer**

*Mitigación inmediata*: identifica la familia que creció (paso 3) y **deja de emitir esa etiqueta**
—en el `MeterFilter` del backend o eliminándola en el collector—. En el plan Free **no se puede
subir el límite**: la única palanca es emitir menos. Si el crecimiento es rotación de versiones
tras un despliegue, espera: las series antiguas expiran solas.

*Arreglo de fondo*: extender la allowlist del `MeterFilter` más allá de `vetsoftware.business.`
para que `email.*` y `lettuce.*` tengan sus etiquetas declaradas y acotadas (TEL-18), y **retirar
lo que nadie consulta** (TEL-39): `sales.lines`, `inventory.units`, `cash.sessions` —que además
duplica la señal de `cash_closing_difference`— y `tokens_purged_total` no tienen panel ni alerta
en ningún stack. Son ~10–15 series por instancia de coste puro.

**Cuándo NO es un incidente**

- Durante y justo después de un despliegue, mientras conviven dos `service_version`. Si baja solo
  en menos de 15 minutos, no llega a madurar el `for`.
- Al activar las recording rules de SLO: es un salto esperado de ~300 series. Anticípalo.
- NoData en esta regla **no** significa que la ingesta esté al límite; significa que el publicador
  de uso de Grafana tuvo un hueco. Por eso `noDataState: OK`.

**Defectos conocidos de la señal**

- **La alerta te dice que creciste, no quién creció.** Es agregada por diseño (una serie de uso por
  instancia), así que los pasos 3–5 son manuales. No hay panel ni regla que atribuya el
  crecimiento a una familia de métricas.
- **El filtro de cardinalidad descarta métricas sin dejar rastro (TEL-04).**
  `BusinessMetricCardinalityFilter.java:97-100` aplica `DENY` al meter completo **sin contador, sin
  log y sin test de paridad con los enums de origen**. `MicrometerBusinessMetrics` deriva valores
  dinámicamente (`lower(status)`, `lower(movementType)`): un valor nuevo en `AppointmentStatus` o
  `StockMovementType` cae fuera de la allowlist y sus incrementos **desaparecen**. En un incidente
  no podrás distinguir «el filtro se la comió» de «no se está emitiendo». Toda ruta de descarte
  debería incrementar una métrica propia y tener alerta.
- **Depende de un tenant que no controlamos.** Si el datasource `grafanacloud-usage` falla, la
  regla entra en `execErrState: Error` y la alerta que protege a todas las demás se queda ciega —
  con la agravante de que su fallo llega como alerta de error de datasource, con otro nombre.
- **No tiene prueba (TEL-30).** Solo 12 de 37 alertas tienen prueba `promtool`, y las reglas
  Grafana-managed **no son testeables con `promtool` en absoluto** porque su formato es el de
  provisioning de Grafana, no reglas de Prometheus. Una regresión en esta expresión pasa el gate
  sin ruido. Una alerta sin prueba es una recomendación.

---

### VetSoftwareBackendTelemetryAbsent

**Qué significa** — Hace quince minutos que no llega ni una sola métrica del backend de producción.
O el proceso está caído, o el camino de exportación OTLP está roto de extremo a extremo. En
cualquiera de los dos casos estás **ciego sobre prod**: ninguna otra alerta tiene datos que
evaluar, así que su silencio no significa nada.

**Es la alerta más importante del inventario y la única que es solo de producción.**

**Qué la dispara** — `observability/grafana-managed/vetsoftware-heartbeat-prod-managed.yml`, grupo
`vetsoftware-heartbeat`, `uid: vetsw-backend-telemetry-absent`, `severity=critical`, evaluación
cada 1 m, `for: 5m`.

```promql
absent_over_time(target_info{job="mainvet/vetsoftware"}[15m])
and on()
absent_over_time(jvm_threads_live{job="mainvet/vetsoftware"}[15m])
> 0
```

**Lo primero que hay que entender: `up` no existe en este stack.** La ingesta es *push* por OTLP,
no *scrape*, así que no hay ninguna serie que diga «el target responde». La caída se detecta por
la **ausencia de series reales**, y eso obliga a invertir la lógica: `absent_over_time` devuelve 1
cuando **no** hay datos, y vacío cuando los hay. Por eso `noDataState: OK` es correcto aunque
parezca al revés — **NoData es el estado sano**; el incidente produce datos (valor 1).

Se exigen **dos** series independientes y siempre presentes mientras el proceso viva: `target_info`
(la publica el recurso OTel en cada export) y `jvm_threads_live` (la publica el runtime sin
depender de tráfico). Con el `and on()` ambas ausencias deben ser ciertas a la vez, así un simple
renombre de una métrica no dispara un falso «backend caído».

**Tiempo real hasta el aviso: hasta 20 minutos** (ventana de 15 m + `for` de 5 m). Es el precio
deliberado de no notificar por un retraso de ingesta.

El tercer escenario —que Mimir o el datasource no respondan, que también es ceguera total— no
produce NoData sino **error de ejecución**, y lo cubre `execErrState: Error`, que genera su propia
alerta con estos mismos labels, `severity=critical` incluido. Llega a Slack, pero **con otro
nombre**: no la busques por este.

**Primero mirar**

1. **ECS antes que nada.** ¿Hay tareas corriendo y cuántas se están pidiendo?

   ```bash
   aws ecs describe-services --cluster <cluster-prod> --services <servicio-backend> \
     --query 'services[0].{running:runningCount,desired:desiredCount,deployments:deployments[].{status:status,rollout:rolloutState}}'
   aws ecs list-tasks --cluster <cluster-prod> --desired-status STOPPED
   ```

   Si `desired > 0` y `running = 0`, es un fallo de arranque: imagen rota, sin capacidad, o crash
   loop. Si `desired = 0`, alguien lo apagó.

2. **El discriminador que ahorra media hora: ¿siguen llegando los logs?** Los logs viajan por
   CloudWatch → Firehose → Loki, un camino **completamente distinto** del OTLP de métricas y
   trazas:

   ```logql
   {service_name="vetsoftware"} | count_over_time([15m])
   ```

   - **Logs llegan y métricas no** → el proceso está vivo; lo roto es la exportación OTLP (el
     sidecar del collector, las credenciales, la red de salida, o Grafana Cloud). Mira las alarmas
     `telemetry-sidecar-stopped` / `telemetry-sidecar-errors` en CloudWatch: el sidecar es
     `essential = false`, así que puede haber muerto **sin** que ECS reemplace la tarea ni emita
     una parada.
   - **Ni logs ni métricas** → el proceso está caído. Vuelve al paso 1.

3. Descarta que sea rechazo de ingesta por límite del plan. Es el escenario que
   `VetSoftwareIngestionNearLimit` anticipa, y produce exactamente este síntoma. En el datasource
   `grafanacloud-usage`:

   ```promql
   last_over_time(grafanacloud_instance_active_series[1h]) / on(id) group_left() grafanacloud_instance_metrics_limits{limit_name="max_active_series_per_user"}
   ```

4. Si el proceso arrancó y murió, mira el arranque: `RemoteConnectionValidator` **se niega a
   arrancar** si `OTEL_EXPORTER_OTLP_HEADERS` está vacía, y también exige presente y remoto el
   endpoint OTLP de logs (`RemoteConnectionValidator.java:388` + `application-prod.yml:63`)
   **aunque esa exportación esté apagada por decisión documentada**. Limpiar del task definition
   una variable «sin uso» tumba el arranque por una ruta que no se usa (TEL-34).

5. Cuando vuelva la señal, confirma qué versión está corriendo:

   ```promql
   count by (service_version) (target_info{job="mainvet/vetsoftware"})
   ```

**Causas habituales**

1. Tareas caídas o sin arrancar: imagen rota, falta de capacidad, crash loop en el arranque,
   fallo del health check.
2. Sidecar del collector detenido. Como es `essential = false`, ECS **no** reemplaza la tarea y
   **no** emite una parada: la API sigue respondiendo perfectamente mientras la telemetría muere.
3. Credenciales OTLP rotadas o revocadas, o el endpoint del stack cambiado.
4. Rechazo de ingesta por haber alcanzado el 100 % del límite del plan.
5. Salida de red bloqueada (security group, NAT, endpoint de VPC) tras un cambio de infraestructura.

**Qué hacer**

*Mitigación inmediata*: si es el sidecar, **fuerza un nuevo despliegue** —ECS no lo va a revivir
solo—. Si son las tareas, aplica el runbook de arranque de ECS. Si es la credencial OTLP, rótala.
Mientras la telemetría no vuelva, **opera contra CloudWatch Logs**, que sigue teniendo todos los
eventos: es el respaldo que sobrevive a este fallo.

*Arreglo de fondo*: el sidecar `essential = false` es una decisión correcta —si el collector cae,
la API sigue en pie— pero su precio es que nadie se entera; las alarmas
`TelemetrySidecarStopped` / `TelemetrySidecarErrors` existen exactamente para cerrar ese hueco y
deben estar cableadas en prod, no solo en dev.

**Cuándo NO es un incidente**

- Un apagado o escalado a cero **deliberado** de producción. Aun así, esta alerta debe sonar: en
  prod no hay apagado programado y una parada intencionada tiene que anunciarse.
- Un despliegue rodante normal **no** debería producir un hueco de 15 minutos: la tarea antigua
  sigue publicando hasta que la nueva está sana. Si esta alerta suena durante un despliegue, el
  despliegue está fallando.
- **El apagado nocturno de dev no aplica aquí, y ese es el motivo de que esta regla sea solo de
  prod.** EventBridge apaga dev a las 20:00/20:15 de Bogotá de lunes a viernes y los fines de
  semana completos: todas las series de la aplicación desaparecen cada noche. **No sincronices
  este fichero a dev bajo ningún concepto** — sonaría cada noche por diseño del ambiente, no por
  un incidente. El equivalente dev de «el backend no está» son los eventos de ECS del lado AWS.

**Defectos conocidos de la señal**

- **~~El enlace del runbook apunta a un ancla que no existe.~~ → CORREGIDO.** La anotación decía
  `#vetsoftwarebackenddown`, el nombre de la alerta *anterior* (la del mundo *scrape*, cuando `up`
  existía), y quien hiciera clic desde Slack en plena caída de producción aterrizaba en ninguna
  parte. Hoy apunta a `#vetsoftwarebackendtelemetryabsent` por URL absoluta. Verificado el
  2026-08-19 cruzando las 26 anotaciones `runbook` contra los encabezados de este documento: **no
  queda ni un ancla huérfana** (dos anclas las comparten dos reglas cada una —las variantes
  `warning`/`critical` de `ScheduledJobFailing` y `EmailSendFailing`— y es correcto).
- **No he podido validar esta regla contra prod.** El único stack con tráfico es dev. Lo que sí
  verifiqué (19-08-2026) es el **mecanismo**: `target_info` y `jvm_threads_live` existen, comparten
  `job="mainvet/vetsoftware"`, llevan `service_version` y `deployment_environment_name=dev`, y
  desaparecen a la vez con el apagado nocturno — que es exactamente el comportamiento que la
  expresión explota. **Antes de habilitar esta regla en prod, comprueba que prod está exportando
  telemetría de verdad**: si el camino de exportación de prod no está desplegado, la regla
  disparará de forma permanente desde el minuto uno y quemará el canal.
- **Hasta 20 minutos de ceguera antes del aviso** (ventana 15 m + `for` 5 m). Es deliberado, pero
  tenlo presente al reconstruir la línea de tiempo del incidente: la caída empezó *al menos* 20
  minutos antes de la notificación.
- **Cuando vuelva la señal, la pregunta «¿esto empezó con el último despliegue?» cuesta más de lo
  que debería (TEL-37).** Las métricas y las trazas llevan `service_version`; **los logs de Loki
  no** — solo `service_name`, `namespace` y `environment`. Hay que triangular por hora entre las
  dos señales. El arreglo es inyectar `service_version` en la transformación de Firehose.
- **La correlación entre señales está rota en dos aristas (TEL-27, TEL-28)**, y las vas a echar de
  menos justo aquí: el *derived field* del stack local busca `"traceId":"..."` cuando por OTLP el
  campo es `trace_id` (el salto log→traza no existe en local), y en el datasource cloud los
  exemplars **sí llegan** pero el datasource espera `traceID` y llega `trace_id`, así que un p99
  alto no te da ninguna traza de ejemplo con un clic. El segundo requiere ticket a Soporte de
  Grafana Cloud; lo ejecuta el dueño de la cuenta, no quien atiende la alerta.

---

## 5. Qué NO se vigila aquí, y por decisión

No todo hueco de cobertura es un olvido. Este apartado existe para que una decisión ya tomada no
haya que volver a tomarla cada seis meses, y para que quien la reabra lo haga con el expediente
completo delante.

### Las cuatro alertas de negocio retiradas

`VetSoftwareDianContingencyRateHigh`, `VetSoftwareDianBacklogOlderThanOneHour`,
`VetSoftwareInventoryInsufficientStockRateHigh` y `VetSoftwareBusinessMetricsSnapshotStale`
existen en el stack Docker local (`VetSoftware/docker/prometheus-business-alerts.yml`) y **no
tienen gemelo en Grafana Cloud**. No es un fallo de la portabilidad: sus métricas existen en
cloud y las reglas llegaron a escribirse. **El dueño del producto decidió no vigilarlas** —«no
me interesan»— y se retiraron enteras: no queda fichero ni namespace `vetsoftware-business`.

**Qué queda sin vigilancia dedicada por esa decisión.** Se dice sin adornos, porque dos de las
cuatro son dominio de dinero y de cumplimiento fiscal:

- **Contingencia de facturación electrónica**: la tasa de documentos emitidos en contingencia no
  tiene alerta propia.
- **Backlog de la DIAN**: que un documento lleve más de una hora pendiente de transmitir no
  dispara nada por sí mismo.
- **Stock insuficiente** en los movimientos de inventario.
- **Frescura del snapshot de métricas de negocio**: si el job que las refresca se para, los
  paneles de negocio se congelan sin avisar a nadie.

**Qué sigue cubriendo ese dominio**, que es lo que hace defendible la decisión: el SLI
`dian-transmission` de la cadena SLO vigila la facturación electrónica por **burn rate**
(`VetSoftwareSloFastBurn` y sus tres hermanas), y `VetSoftwareScheduledJobFailing` cubre los jobs
de reconciliación y de contingencia por el lado de la ejecución. La cobertura de DIAN baja; no
desaparece.

**El matiz temporal, que es lo que hay que saber si alguien reabre esto.** La decisión se tomó
**antes** de saber que la transmisión a la DIAN estaba fallando al **100 %** en dev (documento
atascado, fallo determinista del proveedor). Ese fallo lo destapó el **burn rate del SLO**, no
una alerta de negocio: la vía de cobertura que quedó en pie encontró un incidente real. Queda
escrito como dato del expediente, no como argumento en ninguna dirección — quien quiera revertir
la retirada tiene que decir qué pregunta concreta no responde el burn rate, y quien quiera
mantenerla tiene un caso a favor documentado.

**Cómo se revierte, si algún día se decide.** Es mecánico y no hay que reinventarlo: las reglas
siguen en el historial de git de `observability/mimir-rules/` y en la versión local
(`VetSoftware/docker/prometheus-business-alerts.yml`), y hay que reponerlas en `RULE_FILES` de
los dos workflows de sync. Antes de hacerlo, releer «Qué NO se portó y por qué» del
`README.md` de `observability/mimir-rules/`: la regla de la casa es comprobar primero si el
hallazgo ya está cubierto desde el lado AWS o desde la cadena SLO, y duplicar cobertura tiene su
propio coste.
