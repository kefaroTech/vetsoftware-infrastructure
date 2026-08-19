# Aplica los ficheros de observability/grafana-managed/ (formato de
# provisioning de Grafana, apiVersion 1) contra la API HTTP de provisioning de
# alertas del stack de Grafana Cloud: contact points, notification policy y
# reglas Grafana-managed. Lo invocan sync-alert-rules-dev.yml y
# sync-alert-rules-prod.yml despues del sync de mimirtool.
#
# Por que un script y no un curl por fichero: la API HTTP de provisioning NO
# acepta el formato de fichero (apiVersion 1) tal cual. Cada recurso viaja como
# JSON individual sobre /api/v1/provisioning/... (ProvisionedAlertRule,
# EmbeddedContactPoint, Route). Este script hace la conversion YAML->JSON y el
# upsert idempotente; los modelos del fichero y de la API son la misma familia
# de structs en Grafana, asi que los campos pasan tal cual y solo se anade la
# ubicacion (folderUID, ruleGroup, orgID) que en el fichero es implicita.
#
# CREDENCIAL: un token de SERVICE ACCOUNT de la instancia de Grafana
# (glsa_...), NO el token de Access Policy del ruler. Se comprobo en vivo
# (2026-08-18) que la API de la instancia rechaza el token glc_ del ruler como
# clave ("api-key.invalid"), no como falta de scopes: son dos planos de
# credenciales distintos. Detalle en docs/ALERTAS_GRAFANA_CLOUD.md.
#
# INCERTIDUMBRE DECLARADA (validar en la primera ejecucion con token real):
# las rutas y payloads siguen la documentacion de la Alerting Provisioning
# HTTP API de Grafana, estable desde la v9. No pudieron verificarse contra el
# stack: vastcoyote3439.grafana.net responde 401 ANTES de rutear (una ruta
# inventada tambien devuelve 401, con y sin el token del ruler), asi que solo
# el host esta confirmado (/api/health -> 200, Grafana 13.2.0). Los puntos de
# mayor riesgo estan marcados con "INCIERTO:" en el codigo.
#
# Semantica de salida:
# - 401/403 de la API -> warning y exit 0 (avisa-y-pasa): el service account
#   token no vale o su rol no alcanza. Como crearlo bien:
#   docs/ALERTAS_GRAFANA_CLOUD.md. Fallar aqui pondria en rojo cada merge a
#   develop por una credencial que aun no se ha cargado bien, y el sync del
#   ruler -que corre antes- ya quedo aplicado.
# - Un marcador ${...} sin resolver en el contenido -> exit 1 SIEMPRE: enviar
#   el literal a la API es peor que fallar, porque queda guardado y parece
#   configurado (un correo "${VETSOFTWARE_ALERT_EMAIL}" no notifica a nadie).
# - Cualquier otro fallo -> exit 1.
#
# A diferencia de `mimirtool rules sync`, esto es un UPSERT: crea y actualiza,
# pero NO borra del stack lo que desaparezca del repositorio. Retirar un
# recurso exige un DELETE manual; la asimetria esta documentada en
# docs/ALERTAS_GRAFANA_CLOUD.md para que nadie asuma el "sync borra" del ruler.
[CmdletBinding()]
param(
    # Ficheros de provisioning a aplicar. El tipo de cada uno se detecta por
    # sus claves de primer nivel (contactPoints / policies / groups), y el
    # orden de aplicacion es fijo -contact points, luego policy, luego reglas-
    # porque la policy referencia receivers y las reglas no dependen de nadie.
    [Parameter(Mandatory)]
    [string[]]$Files,

    # Host de la API de Grafana (https://<stack>.grafana.net). Distinto del
    # host del ruler de Mimir.
    [Parameter()]
    [string]$GrafanaApiUrl,

    # Service account token de la instancia de Grafana (glsa_...). Secret
    # PROPIO (GRAFANA_PROVISIONING_TOKEN), separado del token del ruler: son
    # planos de credencial distintos y la instancia rechaza el del ruler.
    [Parameter()]
    [string]$Token,

    # Etiqueta del ambiente, solo para mensajes y summary.
    [Parameter()]
    [string]$EnvironmentLabel = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($GrafanaApiUrl)) {
    $GrafanaApiUrl = [Environment]::GetEnvironmentVariable("GRAFANA_API_URL")
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = [Environment]::GetEnvironmentVariable("GRAFANA_PROVISIONING_TOKEN")
}
if ([string]::IsNullOrWhiteSpace($GrafanaApiUrl) -or [string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "::error::Faltan GRAFANA_API_URL o GRAFANA_PROVISIONING_TOKEN; el sub-gate del workflow deberia haber omitido este paso antes de llegar aqui."
    exit 1
}
$script:BaseUrl = $GrafanaApiUrl.Trim().TrimEnd("/")

$inActions = $env:GITHUB_ACTIONS -eq "true"

function Write-Annotation {
    param(
        [Parameter(Mandatory)][ValidateSet("error", "warning", "notice")][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $color = switch ($Level) { "error" { "Red" } "warning" { "Yellow" } default { "Cyan" } }
    Write-Host "[grafana-provisioning] $Message" -ForegroundColor $color
    if ($inActions) {
        $flattened = $Message -replace "`r?`n", " "
        Write-Host "::${Level}::$flattened"
    }
}

function Write-Summary {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Lines -Encoding utf8
    }
}

# Registro de lo aplicado, para el summary y para el mensaje de avisa-y-pasa
# (si un 403 corta a mitad, hay que decir que quedo aplicado y que no).
$script:Applied = [System.Collections.Generic.List[string]]::new()

function Invoke-GrafanaApi {
    param(
        [Parameter(Mandatory)][ValidateSet("GET", "POST", "PUT")][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][AllowNull()]$Body,
        [Parameter(Mandatory)][string]$Context
    )

    $requestParams = @{
        Method             = $Method
        Uri                = "$script:BaseUrl$Path"
        # NO se envia X-Disable-Provenance a proposito: con provenance "api"
        # Grafana bloquea la edicion de estos objetos en la UI, que es
        # exactamente la disciplina del ruler ("ninguna regla se crea a mano
        # por consola"). El propio script puede seguir actualizandolos porque
        # comparte provenance.
        Headers            = @{ Authorization = "Bearer $Token" }
        # pwsh 7: devuelve la respuesta con su status en vez de lanzar, para
        # poder distinguir 401/403 (avisa-y-pasa) de un error real.
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) {
        $requestParams.ContentType = "application/json"
        $requestParams.Body = ($Body | ConvertTo-Json -Depth 60)
    }

    $response = Invoke-WebRequest @requestParams
    $status = [int]$response.StatusCode

    # Token invalido o con rol insuficiente: el caso esperado hasta que el
    # usuario cree bien el service account token dentro de la instancia (ojo:
    # un token de Access Policy del portal produce exactamente este 401, con
    # "api-key.invalid" en el cuerpo). Avisa-y-pasa, igual que el gate del
    # ruler cuando faltan sus variables. Nota: un 403 a mitad de camino deja
    # aplicado lo anterior; el mensaje lo enumera para que no sea una sorpresa.
    if ($status -in 401, 403) {
        $appliedNote = if ($script:Applied.Count -gt 0) { " Ya aplicado antes del corte: $($script:Applied -join '; ')." } else { " No se aplico nada." }
        Write-Annotation -Level warning -Message "La API de provisioning de Grafana devolvio $status en '$Context' ($Method $Path): el service account token no vale para esta instancia o su rol no alcanza. Si el cuerpo dice 'api-key.invalid', se cargo un token de Access Policy en vez de un service account token. Se omite el provisioning sin fallar.$appliedNote Como crear la credencial correcta: docs/ALERTAS_GRAFANA_CLOUD.md. Respuesta: $($response.Content)"
        Write-Summary -Lines @(
            "### Provisioning de Grafana - $EnvironmentLabel",
            "",
            "OMITIDO: la API devolvio **$status** en ``$Context``. Revise que ``GRAFANA_PROVISIONING_TOKEN`` sea un **service account token** de la instancia (``glsa_...``), no un token de Access Policy (ver ``docs/ALERTAS_GRAFANA_CLOUD.md``).",
            ""
        )
        exit 0
    }

    return [pscustomobject]@{
        Status  = $status
        Content = $response.Content
    }
}

function Assert-Success {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Context
    )
    if ($Response.Status -lt 200 -or $Response.Status -ge 300) {
        Write-Annotation -Level error -Message "Fallo '$Context': HTTP $($Response.Status). Respuesta: $($Response.Content)"
        exit 1
    }
}

# "5m" del fichero -> segundos. INCIERTO: la doc de la API modela el interval
# del rule group como entero en segundos; si la primera ejecucion real lo
# rechaza, este es el primer sitio que revisar.
function ConvertTo-Seconds {
    param([Parameter(Mandatory)][string]$Duration)
    $trimmed = $Duration.Trim()
    if ($trimmed -match '^(\d+)$') { return [int64]$Matches[1] }
    if ($trimmed -match '^(\d+)([smh])$') {
        $value = [int64]$Matches[1]
        switch ($Matches[2]) {
            "s" { return $value }
            "m" { return $value * 60 }
            "h" { return $value * 3600 }
        }
    }
    Write-Annotation -Level error -Message "Duracion de interval no reconocida: '$Duration'. Formatos admitidos: Ns, Nm, Nh o segundos pelados."
    exit 1
}

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory)][AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# --- Parseo de los ficheros -------------------------------------------------

# yq (mikefarah, v4) viene preinstalado en los runners ubuntu-24.04 de GitHub;
# se usa solo como conversor YAML->JSON, sin transformar nada. En local:
# winget install MikeFarah.yq (o choco install yq).
if ($null -eq (Get-Command yq -ErrorAction SilentlyContinue)) {
    Write-Annotation -Level error -Message "yq no esta disponible en el PATH; hace falta para convertir los ficheros de provisioning de YAML a JSON."
    exit 1
}

$contactPointEntries = [System.Collections.Generic.List[object]]::new()
$policyEntries = [System.Collections.Generic.List[object]]::new()
$ruleGroupEntries = [System.Collections.Generic.List[object]]::new()

foreach ($file in $Files) {
    if (-not (Test-Path -LiteralPath $file)) {
        # Fichero listado en PROVISIONING_FILES pero ausente del checkout: eso
        # es un error de configuracion del workflow, no un estado transitorio.
        Write-Annotation -Level error -Message "El fichero de provisioning '$file' esta listado pero no existe en el repositorio. Revise PROVISIONING_FILES en el workflow."
        exit 1
    }
    # Sustitucion de marcadores ${NOMBRE} por variables de entorno ANTES de
    # convertir a JSON (p.ej. ${VETSOFTWARE_ALERT_EMAIL} en los contact
    # points). Solo la forma con llaves: un $ suelto no se toca, que es lo que
    # protege los $labels del templating de Grafana en las annotations. Un
    # marcador cuya variable no existe se deja tal cual y lo caza el control
    # de abajo.
    $raw = Get-Content -LiteralPath $file -Raw -Encoding utf8
    $substituted = [regex]::Replace($raw, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}', {
            param($match)
            $value = [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
            if ([string]::IsNullOrWhiteSpace($value)) { return $match.Value }
            return $value
        })

    $json = $substituted | & yq -o=json '.' -
    if ($LASTEXITCODE -ne 0) {
        Write-Annotation -Level error -Message "yq no pudo parsear '$file' como YAML."
        exit 1
    }
    $jsonText = ($json -join "`n")

    # El control de no-resueltos se hace sobre el JSON y no sobre el texto
    # crudo a proposito: los marcadores en lineas comentadas del YAML (como el
    # webhook de Slack aun sin activar) desaparecen al convertir y no deben
    # exigir su variable todavia. Un marcador que sobreviva hasta aqui iria
    # LITERAL a la API: se guardaria y pareceria configurado (un correo
    # "${VETSOFTWARE_ALERT_EMAIL}" no notifica a nadie). Ese fallo silencioso
    # es peor que un rojo, asi que es error SIEMPRE, incluso en avisa-y-pasa.
    $unresolved = @([regex]::Matches($jsonText, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($unresolved.Count -gt 0) {
        Write-Annotation -Level error -Message "'$file' tiene marcadores sin resolver: $($unresolved -join ', '). Defina esas variables de entorno en el workflow (vars del GitHub Environment) antes de aplicar."
        exit 1
    }

    $parsed = $jsonText | ConvertFrom-Json

    $found = $false
    $cps = Get-OptionalProperty -Object $parsed -Name "contactPoints"
    if ($null -ne $cps) { foreach ($cp in @($cps)) { $contactPointEntries.Add($cp) }; $found = $true }
    $pols = Get-OptionalProperty -Object $parsed -Name "policies"
    if ($null -ne $pols) { foreach ($p in @($pols)) { $policyEntries.Add($p) }; $found = $true }
    $groups = Get-OptionalProperty -Object $parsed -Name "groups"
    if ($null -ne $groups) { foreach ($g in @($groups)) { $ruleGroupEntries.Add($g) }; $found = $true }

    if (-not $found) {
        Write-Annotation -Level error -Message "'$file' no contiene contactPoints, policies ni groups; no es un fichero de provisioning que este script sepa aplicar."
        exit 1
    }
}

# --- 1. Contact points ------------------------------------------------------
# Primero, porque la notification policy referencia receivers por nombre y una
# policy que apunte a un receiver inexistente es un 400 evitable.

if ($contactPointEntries.Count -gt 0) {
    # La lista existente sirve de sonda de scopes (primera llamada autenticada
    # de provisioning) y de indice para el upsert.
    $listResponse = Invoke-GrafanaApi -Method GET -Path "/api/v1/provisioning/contact-points" -Context "listar contact points"
    Assert-Success -Response $listResponse -Context "listar contact points"
    $existingPoints = @($listResponse.Content | ConvertFrom-Json)

    foreach ($entry in $contactPointEntries) {
        foreach ($receiver in @($entry.receivers)) {
            $body = [ordered]@{
                # En el formato de fichero el nombre vive en el grupo y el tipo
                # en cada receiver; la API los quiere juntos por receiver.
                name     = $entry.name
                type     = $receiver.type
                settings = (Get-OptionalProperty -Object $receiver -Name "settings")
            }
            $drm = Get-OptionalProperty -Object $receiver -Name "disableResolveMessage"
            $body.disableResolveMessage = if ($null -ne $drm) { [bool]$drm } else { $false }

            $uid = Get-OptionalProperty -Object $receiver -Name "uid"
            $existing = $null
            if (-not [string]::IsNullOrWhiteSpace($uid)) {
                $body.uid = $uid
                $existing = $existingPoints | Where-Object { (Get-OptionalProperty -Object $_ -Name "uid") -eq $uid } | Select-Object -First 1
            }
            else {
                # Sin uid en el fichero el upsert se apoya en (name, type); es
                # ambiguo si hay dos receivers iguales, asi que solo se acepta
                # cuando el par identifica exactamente uno.
                $matched = @($existingPoints | Where-Object { $_.name -eq $entry.name -and $_.type -eq $receiver.type })
                if ($matched.Count -gt 1) {
                    Write-Annotation -Level error -Message "El receiver '$($entry.name)'/'$($receiver.type)' no tiene uid en el fichero y hay $($matched.Count) contact points con ese nombre y tipo en el stack: el upsert seria ambiguo. Anada un uid estable al receiver."
                    exit 1
                }
                $existing = $matched | Select-Object -First 1
            }

            $label = "contact point '$($entry.name)' ($($receiver.type))"
            if ($null -ne $existing) {
                $existingUid = Get-OptionalProperty -Object $existing -Name "uid"
                $response = Invoke-GrafanaApi -Method PUT -Path "/api/v1/provisioning/contact-points/$([uri]::EscapeDataString($existingUid))" -Body $body -Context "actualizar $label"
                Assert-Success -Response $response -Context "actualizar $label"
                $script:Applied.Add("$label (actualizado)")
            }
            else {
                $response = Invoke-GrafanaApi -Method POST -Path "/api/v1/provisioning/contact-points" -Body $body -Context "crear $label"
                Assert-Success -Response $response -Context "crear $label"
                $script:Applied.Add("$label (creado)")
            }
        }
    }
}

# --- 2. Notification policy -------------------------------------------------
# El arbol de rutas es un singleton por organizacion: PUT lo reemplaza entero.
# El formato de fichero envuelve el mismo struct Route con un orgId que la API
# no admite en el body; se quita y el resto pasa tal cual.

if ($policyEntries.Count -gt 0) {
    if ($policyEntries.Count -gt 1) {
        # Dos arboles en los ficheros = el segundo pisaria al primero en
        # silencio. Mejor pararlo en el log que descubrirlo en el stack.
        Write-Annotation -Level error -Message "Hay $($policyEntries.Count) entradas 'policies' entre los ficheros y la notification policy es unica por organizacion. Consolide en una."
        exit 1
    }
    $tree = $policyEntries[0] | Select-Object -Property * -ExcludeProperty orgId
    $response = Invoke-GrafanaApi -Method PUT -Path "/api/v1/provisioning/policies" -Body $tree -Context "aplicar la notification policy"
    Assert-Success -Response $response -Context "aplicar la notification policy"
    $script:Applied.Add("notification policy (reemplazada)")
}

# --- 3. Reglas Grafana-managed ----------------------------------------------

if ($ruleGroupEntries.Count -gt 0) {
    # La carpeta se referencia por NOMBRE en el fichero pero la API exige su
    # UID. Debe existir de antemano (se crea una vez en la UI: Alerting ->
    # Alert rules -> New folder); crearla desde aqui pediria otro scope mas en
    # la Access Policy para un caso que ocurre una sola vez.
    # INCIERTO: /api/folders es API general de Grafana, no de alert
    # provisioning; no esta confirmado que el token con scopes
    # alert.provisioning baste para listarla. Si devuelve 403 el paso queda en
    # avisa-y-pasa y hay que valorar anadir folders:read a la Access Policy.
    $foldersResponse = Invoke-GrafanaApi -Method GET -Path "/api/folders" -Context "listar carpetas"
    Assert-Success -Response $foldersResponse -Context "listar carpetas"
    $folders = @($foldersResponse.Content | ConvertFrom-Json)

    foreach ($group in $ruleGroupEntries) {
        $folder = $folders | Where-Object { $_.title -eq $group.folder } | Select-Object -First 1
        if ($null -eq $folder) {
            Write-Annotation -Level error -Message "La carpeta '$($group.folder)' no existe en el stack. Creela una vez en la UI (Alerting -> Alert rules -> New folder) y relance el workflow."
            exit 1
        }
        $folderUid = $folder.uid
        $orgId = Get-OptionalProperty -Object $group -Name "orgId"
        if ($null -eq $orgId) { $orgId = 1 }

        foreach ($rule in @($group.rules)) {
            # El rule del fichero y el ProvisionedAlertRule de la API son el
            # mismo modelo salvo la ubicacion, que en el fichero es implicita
            # (grupo y carpeta padres) y aqui viaja en el body.
            $body = $rule | Select-Object -Property *
            $body | Add-Member -NotePropertyName folderUID -NotePropertyValue $folderUid -Force
            $body | Add-Member -NotePropertyName ruleGroup -NotePropertyValue $group.name -Force
            $body | Add-Member -NotePropertyName orgID -NotePropertyValue $orgId -Force

            $ruleUid = Get-OptionalProperty -Object $rule -Name "uid"
            if ([string]::IsNullOrWhiteSpace($ruleUid)) {
                Write-Annotation -Level error -Message "La regla '$($rule.title)' no tiene uid; sin uid el upsert crearia duplicados en cada ejecucion."
                exit 1
            }

            $label = "regla '$($rule.title)'"
            $probe = Invoke-GrafanaApi -Method GET -Path "/api/v1/provisioning/alert-rules/$([uri]::EscapeDataString($ruleUid))" -Context "consultar $label"
            if ($probe.Status -eq 200) {
                $response = Invoke-GrafanaApi -Method PUT -Path "/api/v1/provisioning/alert-rules/$([uri]::EscapeDataString($ruleUid))" -Body $body -Context "actualizar $label"
                Assert-Success -Response $response -Context "actualizar $label"
                $script:Applied.Add("$label (actualizada)")
            }
            elseif ($probe.Status -eq 404) {
                $response = Invoke-GrafanaApi -Method POST -Path "/api/v1/provisioning/alert-rules" -Body $body -Context "crear $label"
                Assert-Success -Response $response -Context "crear $label"
                $script:Applied.Add("$label (creada)")
            }
            else {
                Assert-Success -Response $probe -Context "consultar $label"
            }
        }

        # El interval de evaluacion es propiedad del grupo, no de la regla, y
        # el POST/PUT por regla no lo fija. Se lee el grupo ya materializado,
        # se ajusta solo el interval y se devuelve entero: un PUT parcial
        # podria descartar las reglas del grupo.
        # INCIERTO: ruta /folder/{uid}/rule-groups/{name} e interval en
        # segundos, ambos segun la doc de la API. Por eso un fallo aqui es
        # warning y no error: las reglas ya estan aplicadas y el interval por
        # defecto del stack mantiene la alerta viva aunque evalue mas a menudo.
        $intervalRaw = Get-OptionalProperty -Object $group -Name "interval"
        if ($null -ne $intervalRaw) {
            $groupPath = "/api/v1/provisioning/folder/$([uri]::EscapeDataString($folderUid))/rule-groups/$([uri]::EscapeDataString($group.name))"
            $groupResponse = Invoke-GrafanaApi -Method GET -Path $groupPath -Context "leer el rule group '$($group.name)'"
            if ($groupResponse.Status -eq 200) {
                $materialized = $groupResponse.Content | ConvertFrom-Json
                $materialized | Add-Member -NotePropertyName interval -NotePropertyValue (ConvertTo-Seconds -Duration ([string]$intervalRaw)) -Force
                $putResponse = Invoke-GrafanaApi -Method PUT -Path $groupPath -Body $materialized -Context "fijar el interval del rule group '$($group.name)'"
                if ($putResponse.Status -ge 200 -and $putResponse.Status -lt 300) {
                    $script:Applied.Add("interval del grupo '$($group.name)' = $intervalRaw")
                }
                else {
                    Write-Annotation -Level warning -Message "No se pudo fijar el interval del rule group '$($group.name)' (HTTP $($putResponse.Status)); las reglas quedan aplicadas con el interval por defecto del stack. Respuesta: $($putResponse.Content)"
                }
            }
            else {
                Write-Annotation -Level warning -Message "No se pudo leer el rule group '$($group.name)' para fijar su interval (HTTP $($groupResponse.Status)); las reglas quedan aplicadas con el interval por defecto del stack."
            }
        }
    }
}

# --- Resumen -----------------------------------------------------------------

$summaryLines = [System.Collections.Generic.List[string]]::new()
$summaryLines.Add("### Provisioning de Grafana - $EnvironmentLabel")
$summaryLines.Add("")
if ($script:Applied.Count -eq 0) {
    $summaryLines.Add("Nada que aplicar: los ficheros no contenian recursos.")
}
else {
    $summaryLines.Add("Aplicado (upsert, sin borrado):")
    $summaryLines.Add("")
    foreach ($item in $script:Applied) { $summaryLines.Add("- $item") }
}
Write-Summary -Lines $summaryLines
Write-Host "[grafana-provisioning] OK: $($script:Applied.Count) operaciones aplicadas en $EnvironmentLabel." -ForegroundColor Green
exit 0
