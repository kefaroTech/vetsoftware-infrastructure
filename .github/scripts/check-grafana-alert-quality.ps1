#!/usr/bin/env pwsh
# Validacion OFFLINE de las alertas Grafana-managed de observability/grafana-managed/
# y de su runbook docs/ALERTAMIENTO_OPERATIVO.md. La invoca alert-rules-quality.yml
# en cada pull request que toque cualquiera de los dos.
#
# POR QUE EXISTE: mimirtool -lo unico que validaba el workflow- entiende el formato
# del ruler de Mimir (namespace + groups + expr), NO el formato de provisioning de
# Grafana (apiVersion 1, uid, condition, data[].model). Las 26 alertas que de verdad
# notifican viven en el segundo formato y hasta ahora no las miraba nadie en un PR.
# Los fallos que esto caza YA OCURRIERON y se detectaron a mano: una plantilla Go sin
# validar, una anotacion runbook apuntando a un ancla inexistente y una URL pegada
# del repositorio equivocado.
#
# SIN CREDENCIALES Y SIN RED, A PROPOSITO: un PR corre codigo de una rama cualquiera
# y no debe ver el token del ruler ni el service account de Grafana (misma politica
# que la cabecera de alert-rules-quality.yml). Todo lo de aqui es lectura de fichero.
#
# POR QUE NO SE REUTILIZA .github/scripts/apply-grafana-provisioning.ps1 EN SECO:
# ese script hace tres cosas antes de parsear -sustituir los marcadores dolar-llave
# por variables de entorno, exigir que NINGUNO quede sin resolver (exit 1 SIEMPRE) y
# despachar por tipo hacia la API- y la segunda es incompatible con un PR: en el job
# de calidad no existe VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL, asi que el marcador del
# contact point sobrevive y el script fallaria por diseno. Anadirle un modo seco
# obligaria a relajar justo el control que protege el apply real, y a arrastrar un
# script pensado para credenciales a un job que no debe tenerlas. Lo unico realmente
# comun es "yq -o=json <fichero>", tres lineas, que es lo que se repite aqui.
#
# Codigo de salida: 0 si pasan las 8 comprobaciones, 1 si falla cualquiera.

[CmdletBinding()]
param(
    # Directorio con los ficheros de provisioning de Grafana (apiVersion 1).
    [Parameter()]
    [string]$ProvisioningDir = "observability/grafana-managed",

    # Runbook: el documento al que apuntan las anotaciones `runbook`.
    [Parameter()]
    [string]$RunbookDoc = "docs/ALERTAMIENTO_OPERATIVO.md",

    # Prefijo exigido a toda URL de runbook. Fijo a proposito: pegar la URL del
    # repositorio del backend produce un enlace que abre un 404 y nadie lo nota
    # hasta que alguien lo pulsa a las 3 de la manana.
    [Parameter()]
    [string]$RunbookUrlPrefix = "https://github.com/kefaroTech/vetsoftware-infrastructure/blob/develop/docs/ALERTAMIENTO_OPERATIVO.md#"
)

$ErrorActionPreference = "Stop"

# Desde PowerShell 7.3 un ejecutable nativo que devuelve un codigo distinto de
# cero puede lanzar excepcion cuando ErrorActionPreference es Stop. Aqui NO
# interesa: un yq que falla es un YAML mal escrito, y se quiere reportarlo como
# el problema C6 que es -con nombre de fichero y mensaje- y seguir revisando el
# resto de ficheros, no abortar en el primero con un volcado de PowerShell.
$PSNativeCommandUseErrorActionPreference = $false

# yq (mikefarah v4) emite UTF-8; sin esto PowerShell podria leerlo como OEM y las
# tildes de las anotaciones llegarian rotas a los mensajes de error.
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
    Write-Host "[alert-quality] Aviso: no se pudo fijar UTF-8 en la consola ($($_.Exception.Message))."
}

$script:Failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Message
    )
    $line = "[$Check] $Message"
    $script:Failures.Add($line)
    Write-Host "::error::$line"
}

function Get-Prop {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# Slug estilo GitHub: minusculas, los espacios pasan a guion y se descarta todo lo
# que no sea alfanumerico o guion. Los encabezados de hoy son una sola palabra
# CamelCase, asi que coincide con "quitar lo no alfanumerico"; se implementa la
# variante de GitHub porque es la que decide si el enlace abre de verdad el dia que
# alguien escriba un encabezado con espacios.
function ConvertTo-Slug {
    param([Parameter(Mandatory)][string]$Text)
    $s = $Text.Trim().ToLowerInvariant()
    $s = $s -replace '\s+', '-'
    $s = $s -replace '[^a-z0-9\-]', ''
    return $s
}

# Recorre un objeto JSON y devuelve cada hoja de tipo string con su ruta, para poder
# decir en que campo exacto esta el problema.
function Get-StringLeaf {
    param($Node, [string]$Path = "root")
    $out = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Node) { return $out }
    if ($Node -is [string]) {
        $out.Add([pscustomobject]@{ Path = $Path; Value = $Node })
        return $out
    }
    if ($Node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            foreach ($leaf in (Get-StringLeaf -Node $Node[$i] -Path "$Path[$i]")) { $out.Add($leaf) }
        }
        return $out
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) {
            foreach ($leaf in (Get-StringLeaf -Node $p.Value -Path "$Path.$($p.Name)")) { $out.Add($leaf) }
        }
        return $out
    }
    return $out
}

# Balance de bloques de plantilla Go. No es un parser completo: cuenta aperturas
# (if/with/range/define/block) contra cierres en orden, que es justo el fallo real
# que se cuela hoy -un end de menos-. "else" y "else if" no abren bloque (empiezan
# por else, que no esta en la lista de aperturas) y "template" no necesita cierre.
function Test-GoTemplateBalance {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $openers = @("if", "with", "range", "define", "block")
    $depth = 0
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($Text, '\{\{-?\s*(?<kw>[A-Za-z]+)')) {
        $kw = $m.Groups["kw"].Value
        if ($openers -contains $kw) {
            $depth++
        } elseif ($kw -eq "end") {
            $depth--
            if ($depth -lt 0) {
                $before = $Text.Substring(0, $m.Index)
                $lineNo = ($before -split "`n").Count
                $problems.Add("sobra un cierre 'end' en la linea $lineNo del texto de la plantilla (cierra un bloque que nadie abrio)")
                $depth = 0
            }
        }
    }
    if ($depth -gt 0) {
        $plural = if ($depth -eq 1) { "falta 1 cierre 'end'" } else { "faltan $depth cierres 'end'" }
        $problems.Add("$plural : quedan $depth bloque(s) if/with/range/define sin cerrar")
    }
    return $problems
}

# ---------------------------------------------------------------------------
# Entradas
# ---------------------------------------------------------------------------

if ($null -eq (Get-Command yq -ErrorAction SilentlyContinue)) {
    Write-Host "::error::yq no esta disponible en el PATH; hace falta para parsear los ficheros de provisioning. Viene preinstalado en los runners ubuntu-24.04; en local: winget install MikeFarah.yq"
    exit 1
}

if (-not (Test-Path -LiteralPath $ProvisioningDir)) {
    Write-Host "::error::No existe el directorio de provisioning '$ProvisioningDir'."
    exit 1
}
if (-not (Test-Path -LiteralPath $RunbookDoc)) {
    Write-Host "::error::No existe el runbook '$RunbookDoc'."
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $ProvisioningDir -Filter *.yml -File | Sort-Object Name)
if ($files.Count -eq 0) {
    Write-Host "::error::No hay ficheros *.yml en '$ProvisioningDir'."
    exit 1
}

Write-Host "Ficheros de provisioning ($($files.Count)):"
$files | ForEach-Object { Write-Host "  $($_.Name)" }

# ---------------------------------------------------------------------------
# C6 - El YAML parsea (y de paso alimenta al resto de comprobaciones)
# ---------------------------------------------------------------------------

$parsedFiles = [System.Collections.Generic.List[object]]::new()
foreach ($f in $files) {
    $relative = "$ProvisioningDir/$($f.Name)"
    $json = & yq -o=json "." $f.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-Failure -Check "C6" -Message "'$relative' no parsea como YAML: $($json -join ' ')"
        continue
    }
    try {
        $parsed = ($json -join "`n") | ConvertFrom-Json
    } catch {
        Add-Failure -Check "C6" -Message "'$relative' produjo un JSON que no se pudo leer: $($_.Exception.Message)"
        continue
    }
    $parsedFiles.Add([pscustomobject]@{ Path = $relative; Data = $parsed })
}

# ---------------------------------------------------------------------------
# Inventario de reglas y de encabezados del runbook
# ---------------------------------------------------------------------------

$rules = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $parsedFiles) {
    $groups = Get-Prop -Object $entry.Data -Name "groups"
    if ($null -eq $groups) { continue }
    foreach ($g in @($groups)) {
        $groupName = Get-Prop -Object $g -Name "name"
        foreach ($r in @(Get-Prop -Object $g -Name "rules")) {
            if ($null -eq $r) { continue }
            $rules.Add([pscustomobject]@{
                    File    = $entry.Path
                    Group   = $groupName
                    Uid     = Get-Prop -Object $r -Name "uid"
                    Title   = Get-Prop -Object $r -Name "title"
                    Runbook = Get-Prop -Object (Get-Prop -Object $r -Name "annotations") -Name "runbook"
                })
        }
    }
}

$docLines = @(Get-Content -LiteralPath $RunbookDoc -Encoding utf8)
$headings = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $docLines.Count; $i++) {
    if ($docLines[$i] -match '^###\s+(VetSoftware.*)$') {
        $headings.Add([pscustomobject]@{
                Line = $i + 1
                Text = $Matches[1].Trim()
                Slug = ConvertTo-Slug -Text $Matches[1]
            })
    }
}

Write-Host ""
Write-Host "Reglas Grafana-managed encontradas: $($rules.Count)"
Write-Host "Encabezados '### VetSoftware*' en ${RunbookDoc}: $($headings.Count)"

if ($rules.Count -eq 0) {
    Add-Failure -Check "C1" -Message "No se encontro ninguna regla en '$ProvisioningDir'. O el directorio se vacio o el formato cambio; en ambos casos esta validacion dejaria de proteger nada."
}
if ($headings.Count -eq 0) {
    Add-Failure -Check "C3" -Message "No se encontro ningun encabezado '### VetSoftware*' en '$RunbookDoc'."
}

# ---------------------------------------------------------------------------
# C1 - Toda regla tiene anotacion runbook
# ---------------------------------------------------------------------------

$withRunbook = 0
foreach ($r in $rules) {
    if ([string]::IsNullOrWhiteSpace($r.Title)) {
        Add-Failure -Check "C1" -Message "Hay una regla sin 'title' en $($r.File), grupo '$($r.Group)' (uid: $($r.Uid))."
        continue
    }
    if ([string]::IsNullOrWhiteSpace($r.Runbook)) {
        Add-Failure -Check "C1" -Message "La regla '$($r.Title)' ($($r.File), grupo '$($r.Group)') no tiene la anotacion 'runbook'. Sin ella la notificacion de Slack llega sin enlace a que hacer."
        continue
    }
    $withRunbook++
}
Write-Host "C1: $withRunbook de $($rules.Count) reglas con anotacion 'runbook'."

# ---------------------------------------------------------------------------
# C4 - Prefijo de URL fijo   /   C2 - el ancla existe en el runbook
# ---------------------------------------------------------------------------

$headingSlugs = @($headings | ForEach-Object { $_.Slug })
$referenced = [System.Collections.Generic.HashSet[string]]::new()

foreach ($r in $rules) {
    if ([string]::IsNullOrWhiteSpace($r.Runbook)) { continue }
    $url = $r.Runbook.Trim()

    if (-not $url.StartsWith($RunbookUrlPrefix, [System.StringComparison]::Ordinal)) {
        Add-Failure -Check "C4" -Message "La regla '$($r.Title)' ($($r.File)) apunta a '$url', que no empieza por el prefijo exigido '$RunbookUrlPrefix'. Toda URL de runbook debe apuntar a ESTE repositorio y a ESTE documento en la rama develop."
        continue
    }

    $anchor = $url.Substring($RunbookUrlPrefix.Length)
    if ([string]::IsNullOrWhiteSpace($anchor)) {
        Add-Failure -Check "C2" -Message "La regla '$($r.Title)' ($($r.File)) tiene una URL de runbook sin fragmento tras '#': apunta al documento entero, no a su seccion."
        continue
    }
    [void]$referenced.Add($anchor)

    if ($headingSlugs -notcontains $anchor) {
        $prefixLen = [Math]::Min(12, $anchor.Length)
        $near = @($headingSlugs | Where-Object { $_.StartsWith($anchor.Substring(0, $prefixLen)) })
        $suggestion = ""
        if ($near.Count -gt 0) { $suggestion = " Anclas parecidas que si existen: $($near -join ', ')." }
        $expected = ConvertTo-Slug -Text $r.Title
        Add-Failure -Check "C2" -Message "La regla '$($r.Title)' ($($r.File)) apunta al ancla '#$anchor', que NO corresponde a ningun encabezado '### VetSoftware*' de $RunbookDoc. El ancla derivada de su titulo seria '#$expected'.$suggestion"
    }
}
Write-Host "C2/C4: $($referenced.Count) anclas distintas referenciadas por $withRunbook reglas."

# ---------------------------------------------------------------------------
# C3 - Todo encabezado tiene su regla (y ningun encabezado esta duplicado)
# ---------------------------------------------------------------------------

foreach ($h in $headings) {
    if (-not $referenced.Contains($h.Slug)) {
        Add-Failure -Check "C3" -Message "El encabezado '### $($h.Text)' ($($RunbookDoc):$($h.Line)) no lo referencia ninguna regla. O falta la anotacion 'runbook' que apunte a el, o la regla se borro y la seccion sobrevivio describiendo un sistema que ya no existe."
    }
}

$dupSlugs = @($headings | Group-Object -Property Slug | Where-Object { $_.Count -gt 1 })
foreach ($d in $dupSlugs) {
    $dupLines = (($d.Group | ForEach-Object { $_.Line }) -join ", ")
    Add-Failure -Check "C3" -Message "El ancla '#$($d.Name)' la generan $($d.Count) encabezados de $RunbookDoc (lineas $dupLines). GitHub anade un sufijo -1 al segundo, asi que el enlace del runbook abre siempre el primero y la seccion repetida queda inalcanzable."
}
Write-Host "C3: $($headings.Count) encabezados, $($dupSlugs.Count) anclas duplicadas."

# ---------------------------------------------------------------------------
# C5 - Ninguna consulta con _seconds_
# ---------------------------------------------------------------------------
#
# TEL-01 en forma mecanica: el backend exporta por OTLP y Micrometer emite en
# MILISEGUNDOS (http_server_requests_milliseconds_*). Una consulta con _seconds_ no
# falla: devuelve vacio, la alerta se queda en OK y parece que no hay problema.
#
# ALCANCE DELIBERADO: se marca _seconds_ dentro de los BLOQUES DE CODIGO del runbook
# (lo que alguien copia y pega) y dentro de los ficheros de provisioning (lo que
# evalua de verdad). En la PROSA del documento la cadena aparece a proposito una
# decena de veces, en frases que advierten precisamente de este error
# ("_milliseconds_, nunca _seconds_"). Una prohibicion literal sobre todo el fichero
# solo se podria satisfacer borrando esas advertencias, que es justo lo contrario de
# lo que se busca.

$inFence = $false
$fenceCount = 0
for ($i = 0; $i -lt $docLines.Count; $i++) {
    $line = $docLines[$i]
    if ($line -match '^\s*```') {
        $inFence = -not $inFence
        $fenceCount++
        continue
    }
    if ($inFence -and $line -match '_seconds_') {
        Add-Failure -Check "C5" -Message "$($RunbookDoc):$($i + 1) usa '_seconds_' dentro de un bloque de codigo: '$($line.Trim())'. El backend exporta en milisegundos por OTLP; esa consulta devuelve vacio sin avisar y la alerta se queda en OK (TEL-01). Use '_milliseconds_'."
    }
}
if ($inFence) {
    Add-Failure -Check "C5" -Message "$RunbookDoc tiene un numero impar de vallas de codigo: hay un bloque sin cerrar, asi que la comprobacion de '_seconds_' no puede fiarse de donde empieza y acaba el codigo."
}

$secondsInRules = 0
foreach ($entry in $parsedFiles) {
    foreach ($leaf in (Get-StringLeaf -Node $entry.Data)) {
        if ($leaf.Value -match '_seconds_') {
            Add-Failure -Check "C5" -Message "$($entry.Path) usa '_seconds_' en $($leaf.Path): '$($leaf.Value.Trim())'. En Grafana Cloud esa familia de metricas NO existe (el backend emite '_milliseconds_'): la regla evaluaria vacio para siempre y no disparara nunca."
            $secondsInRules++
        }
    }
}
Write-Host "C5: $fenceCount vallas de codigo recorridas en el runbook; $secondsInRules usos de '_seconds_' en el provisioning."

# ---------------------------------------------------------------------------
# C7 - Balance de plantillas Go
# ---------------------------------------------------------------------------
#
# Se aplica a TODA cadena de TODOS los ficheros de provisioning que contenga la
# apertura de plantilla, no solo a los contact points: una anotacion de regla con un
# if sin cerrar rompe igual. Hoy las reglas solo usan $labels, que no abre bloque.

$templatesChecked = 0
foreach ($entry in $parsedFiles) {
    foreach ($leaf in (Get-StringLeaf -Node $entry.Data)) {
        if ($leaf.Value -notmatch '\{\{') { continue }
        $templatesChecked++
        foreach ($problem in (Test-GoTemplateBalance -Text $leaf.Value)) {
            Add-Failure -Check "C7" -Message "Plantilla Go desbalanceada en $($entry.Path), campo $($leaf.Path): $problem. Grafana acepta el fichero igual y el fallo solo se ve cuando llega una notificacion vacia o truncada."
        }
    }
}
Write-Host "C7: $templatesChecked cadenas con plantilla Go revisadas."

# ---------------------------------------------------------------------------
# C8 - Ningun uid de mas de 40 caracteres
# ---------------------------------------------------------------------------
#
# Grafana valida la longitud del uid al CREAR el objeto y responde 400
# ("cannot create rule with UID '...': UID is longer than 40 symbols"). El
# limite es de la API, no del fichero: el YAML parsea igual, el fichero es
# valido, y las comprobaciones C1-C7 -que miran forma, anclas y plantillas- lo
# dan por bueno. El fallo solo aparece al aplicar.
#
# YA OCURRIO, y por eso esto existe: la regla
# `vetsw-scheduled-job-failing-critical-slow` (41 caracteres) paso el gate en el
# PR #162 y reventó el apply a dev (run 32331306479). Lo caro no fue el rojo,
# fue el ESTADO PARCIAL: apply-grafana-provisioning.ps1 va objeto a objeto y
# sale con exit 1 en el primer no-2xx (Assert-Success), asi que las dos reglas
# anteriores del grupo quedaron ya actualizadas con su matcher NUEVO -que
# excluye los jobs DIAN- y la que debia recogerlos nunca se creo. Resultado:
# los jobs de facturacion electronica se quedaron sin alerta critica y nada lo
# dijo, porque el rojo estaba en el workflow y no en Grafana.
#
# Se comprueban los uid de REGLA y los de CONTACT POINT: son el mismo validador
# de Grafana sobre el mismo camino de apply, y un contact point que no se puede
# crear deja sin destino a todas las alertas que lo referencian.

$MaxUidLength = 40

$uids = [System.Collections.Generic.List[object]]::new()
foreach ($r in $rules) {
    if ([string]::IsNullOrWhiteSpace($r.Uid)) { continue }
    $uids.Add([pscustomobject]@{ Kind = "regla '$($r.Title)'"; File = $r.File; Uid = $r.Uid })
}
foreach ($entry in $parsedFiles) {
    foreach ($cp in @(Get-Prop -Object $entry.Data -Name "contactPoints")) {
        if ($null -eq $cp) { continue }
        $cpName = Get-Prop -Object $cp -Name "name"
        foreach ($receiver in @(Get-Prop -Object $cp -Name "receivers")) {
            if ($null -eq $receiver) { continue }
            $cpUid = Get-Prop -Object $receiver -Name "uid"
            if ([string]::IsNullOrWhiteSpace($cpUid)) { continue }
            $uids.Add([pscustomobject]@{ Kind = "contact point '$cpName'"; File = $entry.Path; Uid = $cpUid })
        }
    }
}

$longest = 0
foreach ($u in $uids) {
    $len = $u.Uid.Length
    if ($len -gt $longest) { $longest = $len }
    if ($len -gt $MaxUidLength) {
        $excess = $len - $MaxUidLength
        Add-Failure -Check "C8" -Message "El uid '$($u.Uid)' de la $($u.Kind) ($($u.File)) mide $len caracteres y el maximo de Grafana son $MaxUidLength (sobran $excess). La API responde 400 al crearlo y el apply aborta ahi: los objetos aplicados ANTES quedan con su definicion nueva y los de despues no se aplican, o sea el stack a medias entre dos versiones. Acortelo sin perder el prefijo de familia (p.ej. 'critical' -> 'crit') y actualice TODAS sus referencias: runbook, notification policy y comentarios."
    }
}
Write-Host "C8: $($uids.Count) uid revisados, el mas largo mide $longest de $MaxUidLength permitidos."

# ---------------------------------------------------------------------------
# Resultado
# ---------------------------------------------------------------------------

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "FALLO: $($script:Failures.Count) problema(s)."
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = @("## Calidad de alertas Grafana-managed", "", "**$($script:Failures.Count) problema(s):**", "")
        $summary += @($script:Failures | ForEach-Object { "- $_" })
        ($summary -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    exit 1
}

Write-Host "OK: $($rules.Count) reglas, $withRunbook anotaciones runbook, $($headings.Count) secciones del runbook, $($parsedFiles.Count) ficheros YAML, $templatesChecked plantillas Go y $($uids.Count) uid verificados."
if ($env:GITHUB_STEP_SUMMARY) {
    @(
        "## Calidad de alertas Grafana-managed",
        "",
        "| Comprobacion | Resultado |",
        "| --- | --- |",
        "| C1 anotacion runbook en toda regla | $withRunbook/$($rules.Count) |",
        "| C2 el ancla existe en el runbook | $($referenced.Count) anclas OK |",
        "| C3 seccion del runbook sin regla | 0 de $($headings.Count) |",
        "| C4 prefijo de URL exigido | $withRunbook/$withRunbook |",
        "| C5 metricas en '_seconds_' | 0 |",
        "| C6 el YAML parsea | $($parsedFiles.Count)/$($files.Count) |",
        "| C7 plantillas Go balanceadas | $templatesChecked |",
        "| C8 uid dentro del limite de $MaxUidLength | $($uids.Count) uid, el mayor de $longest |"
    ) -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
exit 0
