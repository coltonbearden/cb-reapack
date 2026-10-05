#Requires -Version 7.0
<#
.SYNOPSIS
  LLM bridge, one run per request (D-21): read <JobDir>\request.json, ask the model, write
  <JobDir>\response.json.

.DESCRIPTION
  Started by scripts\lib\bridge.lua through conhost --headless (D-28); not meant to be run by hand
  except to debug a job.
  1. Checks the request against schema\request.schema.json (D-24).
  2. Posts it to the OpenAI-compatible endpoint in bridge.config.json, or in the shipped
     bridge.config.example.json when there is no bridge.config.json (D-20, D-73), with the action's
     schema\<action>.result.schema.json as response_format; the config's "actions" entry for the
     action overrides temperature, maxTokens and reasoningEffort (D-31), and the request's options
     override model (one of the config's "models") and reasoningEffort (D-54). Sends a Bearer token only
     when %LOCALAPPDATA%\reaper-bridge\token exists (D-23). A request that carries offline_result
     is answered with that object instead of calling the model (the hook the test cases use).
  3. Checks the model's JSON against the result schema and the reply against
     schema\response.schema.json, then writes response.json atomically (tmp file + rename).
  Any failure becomes a status "error" response, so the caller never waits out its timeout on a
  bridge fault. Each run appends to <JobDir>\bridge.log; the token is never logged.

.EXAMPLE
  pwsh -NoProfile -File scripts\bridge\bridge.ps1 -JobDir "$env:LOCALAPPDATA\reaper-bridge\jobs\<id>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$JobDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SchemaDir = Join-Path $PSScriptRoot 'schema'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Clock     = [System.Diagnostics.Stopwatch]::StartNew()

function Write-BridgeLog([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff'), $Message
    [System.IO.File]::AppendAllText((Join-Path $JobDir 'bridge.log'), "$line`n", $Utf8NoBom)
}

# StrictMode-safe property read: $null when the property is absent.
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# Messages for every way $Json fails the schema in $SchemaFile; empty when it passes.
function Get-SchemaError([string]$Json, [string]$SchemaFile) {
    $errs = $null
    $ok = Test-Json -Json $Json -Schema ([System.IO.File]::ReadAllText($SchemaFile)) -ErrorAction SilentlyContinue -ErrorVariable errs
    if ($ok) { return @() }
    @($errs | ForEach-Object { $_.Exception.Message -replace '^The JSON is not valid with the schema: ', '' })
}

function Write-Response([System.Collections.IDictionary]$Response) {
    $Response['schema_version'] = 1
    $Response['elapsed_ms'] = [int]$Clock.ElapsedMilliseconds
    $json = $Response | ConvertTo-Json -Depth 32 -Compress
    $errs = @(Get-SchemaError $json (Join-Path $SchemaDir 'response.schema.json'))
    if ($errs.Count -gt 0) {
        Write-BridgeLog "response failed response.schema.json: $($errs -join '; ')"
        $json = [ordered]@{
            schema_version = 1; id = $Response['id']; status = 'error'; elapsed_ms = $Response['elapsed_ms']
            error = "bridge fault: the response failed response.schema.json: $($errs -join '; ')"
        } | ConvertTo-Json -Compress
    }
    $path = Join-Path $JobDir 'response.json'
    [System.IO.File]::WriteAllText("$path.tmp", $json, $Utf8NoBom)
    Write-BridgeLog "response status=$($Response['status']) elapsed_ms=$($Response['elapsed_ms'])"
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force   # last step: the caller reads it at once
}

$id = Split-Path -Leaf $JobDir
try {
    Write-BridgeLog "start pid=$PID"
    # A user's own bridge.config.json, else the shipped example (D-73); scripts\lib\bridge.lua picks the same.
    $configName = 'bridge.config.json'
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $configName))) { $configName = 'bridge.config.example.json' }
    Write-BridgeLog "config $configName"
    $config = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $configName)) | ConvertFrom-Json -DateKind String
    foreach ($key in 'baseUrl', 'model', 'temperature', 'maxTokens', 'httpTimeoutSeconds') {
        if ($null -eq (Get-Prop $config $key)) { throw "$configName has no '$key'" }
    }

    $requestJson = [System.IO.File]::ReadAllText((Join-Path $JobDir 'request.json'))
    $errs = @(Get-SchemaError $requestJson (Join-Path $SchemaDir 'request.schema.json'))
    if ($errs.Count -gt 0) { throw "the request failed request.schema.json: $($errs -join '; ')" }
    $req = $requestJson | ConvertFrom-Json -DateKind String
    if ($req.id -ne $id) { throw "request id '$($req.id)' does not match the job directory '$id'" }

    $resultSchemaFile = Join-Path $SchemaDir "$($req.action).result.schema.json"
    if (-not (Test-Path -LiteralPath $resultSchemaFile)) { throw "unknown action '$($req.action)' (no schema\$($req.action).result.schema.json)" }
    Write-BridgeLog "request action=$($req.action) extra_chars=$("$(Get-Prop $req 'extra')".Length) request_bytes=$($requestJson.Length)"

    $override = Get-Prop (Get-Prop $config 'actions') $req.action
    foreach ($key in 'temperature', 'maxTokens', 'reasoningEffort') {
        $value = Get-Prop $override $key
        if ($null -ne $value) { $config | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force }
    }
    # Per-run choices from the console (D-54) come last; only a model listed in the config is sent.
    $options = Get-Prop $req 'options'
    $optModel = Get-Prop $options 'model'
    if ($null -ne $optModel) {
        $models = Get-Prop $config 'models'
        if ($null -eq $models) { $models = @($config.model) }
        if ($optModel -notin $models) { throw "model '$optModel' is not in $configName models ($($models -join ', '))" }
        $config | Add-Member -NotePropertyName model -NotePropertyValue $optModel -Force
    }
    $optEffort = Get-Prop $options 'reasoningEffort'
    if ($null -ne $optEffort) { $config | Add-Member -NotePropertyName reasoningEffort -NotePropertyValue $optEffort -Force }
    Write-BridgeLog "settings model=$($config.model) reasoning_effort=$(Get-Prop $config 'reasoningEffort') temperature=$($config.temperature) max_tokens=$($config.maxTokens)"

    $offline = Get-Prop $req 'offline_result'
    if ($null -ne $offline) {
        $model = 'offline'
        $usage = $null
        $resultJson = $offline | ConvertTo-Json -Depth 32 -Compress
        Write-BridgeLog 'offline_result present: the model is not called'
    } else {
        $user = "Project summary (JSON):`n" + ($req.context | ConvertTo-Json -Depth 32 -Compress)
        $extra = "$(Get-Prop $req 'extra')".Trim()
        if ($extra) { $user += "`n`nExtra instruction: $extra" }

        $schema = [System.IO.File]::ReadAllText($resultSchemaFile) | ConvertFrom-Json -AsHashtable
        foreach ($k in '$schema', '$comment') { $schema.Remove($k) }   # annotations, not constraints
        $body = [ordered]@{
            model           = $config.model
            messages        = @(@{ role = 'system'; content = $req.prompt }, @{ role = 'user'; content = $user })
            temperature     = $config.temperature
            max_tokens      = $config.maxTokens
            response_format = @{ type = 'json_schema'; json_schema = @{ name = $req.action; schema = $schema } }
        }
        $effort = Get-Prop $config 'reasoningEffort'
        if ($effort) { $body['reasoning_effort'] = $effort }

        $headers = @{}
        $tokenFile = Join-Path $env:LOCALAPPDATA 'reaper-bridge\token'
        if (Test-Path -LiteralPath $tokenFile) { $headers['Authorization'] = 'Bearer ' + [System.IO.File]::ReadAllText($tokenFile).Trim() }

        $uri = $config.baseUrl.TrimEnd('/') + '/chat/completions'
        Write-BridgeLog "POST $uri model=$($config.model) reasoning_effort=$effort temperature=$($config.temperature) max_tokens=$($config.maxTokens) token=$($headers.ContainsKey('Authorization'))"
        $payload = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 32 -Compress))
        $reply = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec $config.httpTimeoutSeconds

        $choice = @(Get-Prop $reply 'choices')[0]
        $message = Get-Prop $choice 'message'
        $resultJson = "$(Get-Prop $message 'content')"
        $usage = Get-Prop $reply 'usage'
        $model = "$(Get-Prop $reply 'model')"
        if (-not $model) { $model = $config.model }
        Write-BridgeLog "reply model=$model finish_reason=$(Get-Prop $choice 'finish_reason') usage=$($usage | ConvertTo-Json -Compress)"
        if ([string]::IsNullOrWhiteSpace($resultJson)) { throw "the model returned no content (finish_reason=$(Get-Prop $choice 'finish_reason'))" }
    }

    $errs = @(Get-SchemaError $resultJson $resultSchemaFile)
    if ($errs.Count -gt 0) { throw "the model output failed $($req.action).result.schema.json: $($errs -join '; ')" }
    $response = [ordered]@{ id = $id; status = 'ok'; action = $req.action; model = $model; result = ($resultJson | ConvertFrom-Json -DateKind String) }
    if ($null -ne $usage) { $response['usage'] = $usage }
    Write-Response $response
}
catch {
    $msg = "$_"
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg += " | $($_.ErrorDetails.Message)" }
    Write-BridgeLog "error: $msg"
    Write-Response ([ordered]@{ id = $id; status = 'error'; error = $msg })
}
