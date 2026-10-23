#Requires -Version 7.0
<#
.SYNOPSIS
  LLM bridge, one run per request (D-21): read <JobDir>\request.json, ask the model, write
  <JobDir>\response.json.

.DESCRIPTION
  Started by scripts\lib\bridge.lua through conhost --headless (D-28); not meant to be run by hand
  except to debug a job.
  1. Checks the request against schema\request.schema.json (D-24).
  2. Reads bridge.config.json, or the shipped bridge.config.example.json when there is no
     bridge.config.json (D-20, D-73), or -ConfigPath. The run's settings come from the config, its
     "actions" entry for the action (D-31), the model's own entry and the request's options (D-54,
     D-88); only a model listed in the config's "models" is accepted from options.
  3. Asks the model's provider (D-88):
     - ollama: the OpenAI-compatible chat endpoint at baseUrl, with the action's
       schema\<action>.result.schema.json as response_format. A Bearer token is sent only when the
       provider's token file (%LOCALAPPDATA%\reaper-bridge\token) exists (D-23).
     - anthropic: the Messages API, with the schema as output_config.format, less the keywords
       structured outputs refuse (D-89), and the reasoning effort as output_config.effort (D-90).
       The API key is read from its DPAPI file on each run (D-91, Set-BridgeKey.ps1).
     A request that carries offline_result is answered with that object instead of calling a model
     (the hook the test cases use).
  4. Checks the model's JSON against the full result schema and the reply against
     schema\response.schema.json, then writes response.json atomically (tmp file + rename), with the
     provider, the tokens and an estimated cost (D-94).
  Any failure becomes a status "error" response, so the caller never waits out its timeout on a
  bridge fault. Each run appends to <JobDir>\bridge.log; the token and the key are never logged.

.EXAMPLE
  pwsh -NoProfile -File scripts\bridge\bridge.ps1 -JobDir "$env:LOCALAPPDATA\reaper-bridge\jobs\<id>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$JobDir,
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BridgeLib.ps1')

$SchemaDir = Join-Path $PSScriptRoot 'schema'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Clock     = [System.Diagnostics.Stopwatch]::StartNew()

function Write-BridgeLog([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff'), $Message
    [System.IO.File]::AppendAllText((Join-Path $JobDir 'bridge.log'), "$line`n", $Utf8NoBom)
}

# Messages for every way $Json fails the schema in $SchemaFile; empty only when it passes.
# PowerShell 7.6 returns $false for a schema violation without an error record, so a failure
# always yields at least one message (fails closed).
function Get-SchemaError([string]$Json, [string]$SchemaFile) {
    $errs = $null
    $ok = Test-Json -Json $Json -Schema ([System.IO.File]::ReadAllText($SchemaFile)) -ErrorAction SilentlyContinue -ErrorVariable errs
    if ($ok) { return @() }
    $msgs = @($errs | ForEach-Object { $_.Exception.Message -replace '^The JSON is not valid with the schema: ', '' })
    if ($msgs.Count -eq 0) { $msgs = @("does not match $(Split-Path -Leaf $SchemaFile) (Test-Json gave no detail)") }
    $msgs
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

# Records what a reply cost (D-94); also on an error after the reply, since its tokens are billed.
function Set-RunCost([string]$Provider, [string]$Model, $Usage, $Price) {
    $script:RunProvider = $Provider
    $script:RunCost = Get-BridgeCost $Provider $Usage $Price
    $usd = if ($null -eq $script:RunCost.usd) { 'unknown' } else { $script:RunCost.usd }
    Write-BridgeLog "usage provider=$Provider model=$Model input_tokens=$($script:RunCost.input_tokens) output_tokens=$($script:RunCost.output_tokens) cost_usd=$usd"
}

$id = Split-Path -Leaf $JobDir
$RunProvider = $null
$RunCost = $null
try {
    Write-BridgeLog "start pid=$PID"
    $configFile = Get-BridgeConfigFile $ConfigPath
    $configName = Split-Path -Leaf $configFile
    Write-BridgeLog "config $configName"
    $config = [System.IO.File]::ReadAllText($configFile) | ConvertFrom-Json -DateKind String
    foreach ($key in 'model', 'temperature', 'maxTokens', 'httpTimeoutSeconds') {
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

    $s = Resolve-BridgeSettings $config $req.action (Get-Prop $req 'options') $configName
    $temperature = if ($s.provider -eq 'anthropic') { 'n/a' } else { $s.temperature }
    Write-BridgeLog "settings model=$($s.model) reasoning_effort=$($s.reasoningEffort) temperature=$temperature max_tokens=$($s.maxTokens) provider=$($s.provider) http_timeout_s=$($s.httpTimeoutSeconds)"

    $offline = Get-Prop $req 'offline_result'
    if ($null -ne $offline) {
        $model = 'offline'
        $usage = $null
        $RunProvider = 'offline'
        $RunCost = [ordered]@{ input_tokens = 0; output_tokens = 0; usd = 0; price = $null }
        $resultJson = $offline | ConvertTo-Json -Depth 32 -Compress
        Write-BridgeLog 'offline_result present: the model is not called'
    } else {
        $user = "Project summary (JSON):`n" + ($req.context | ConvertTo-Json -Depth 32 -Compress)
        $extra = "$(Get-Prop $req 'extra')".Trim()
        if ($extra) { $user += "`n`nExtra instruction: $extra" }

        $schema = [System.IO.File]::ReadAllText($resultSchemaFile) | ConvertFrom-Json -AsHashtable
        $provider = Get-BridgeProvider $config $s.provider $configName
        if ($s.provider -eq 'anthropic') {
            $key = Read-BridgeSecret $provider.keyFile 'anthropic key'
            if ($null -eq $key) {
                throw "$($s.model) is a Claude model, and no Anthropic API key is stored ($($provider.keyFile)); store one with bridge\Set-BridgeKey.ps1"
            }
            $headers = @{ 'x-api-key' = $key; 'anthropic-version' = $BridgeAnthropicVersion }
            $key = $null
            if ($provider.workspaceId) { $headers['anthropic-workspace-id'] = $provider.workspaceId }
            $body = New-AnthropicBody $s $req.prompt $user $schema
            $uri = $provider.baseUrl.TrimEnd('/') + '/v1/messages'
            Write-BridgeLog "POST $uri model=$($s.model) effort=$($s.reasoningEffort) max_tokens=$($s.maxTokens) key=present workspace=$(if ($provider.workspaceId) { $provider.workspaceId } else { 'from-key' })"
            $payload = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 32 -Compress))
            try {
                $reply = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec $s.httpTimeoutSeconds
            } finally { $headers = $null }

            $parsed = Read-AnthropicReply $reply
            $usage = $parsed.usage
            $model = $parsed.model
            if (-not $model) { $model = $s.model }
            Write-BridgeLog "reply model=$model stop_reason=$($parsed.stop_reason) usage=$($usage | ConvertTo-Json -Compress)"
            Set-RunCost 'anthropic' $model $usage $s.price
            $problem = Get-AnthropicReplyProblem $parsed $s $configName
            if ($problem) { throw $problem }
            $resultJson = $parsed.text
        } else {
            foreach ($k in '$schema', '$comment') { $schema.Remove($k) }   # annotations, not constraints
            $body = [ordered]@{
                model           = $s.model
                messages        = @(@{ role = 'system'; content = $req.prompt }, @{ role = 'user'; content = $user })
                temperature     = $s.temperature
                max_tokens      = $s.maxTokens
                response_format = @{ type = 'json_schema'; json_schema = @{ name = $req.action; schema = $schema } }
            }
            $effort = $s.reasoningEffort
            if ($effort) { $body['reasoning_effort'] = $effort }

            $headers = @{}
            if (Test-Path -LiteralPath $provider.tokenFile) { $headers['Authorization'] = 'Bearer ' + [System.IO.File]::ReadAllText($provider.tokenFile).Trim() }

            $uri = $provider.baseUrl.TrimEnd('/') + '/chat/completions'
            Write-BridgeLog "POST $uri model=$($s.model) reasoning_effort=$effort temperature=$($s.temperature) max_tokens=$($s.maxTokens) token=$($headers.ContainsKey('Authorization'))"
            $payload = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 32 -Compress))
            $reply = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec $s.httpTimeoutSeconds

            $choice = @(Get-Prop $reply 'choices')[0]
            $message = Get-Prop $choice 'message'
            $resultJson = "$(Get-Prop $message 'content')"
            $usage = Get-Prop $reply 'usage'
            $model = "$(Get-Prop $reply 'model')"
            if (-not $model) { $model = $s.model }
            Write-BridgeLog "reply model=$model finish_reason=$(Get-Prop $choice 'finish_reason') usage=$($usage | ConvertTo-Json -Compress)"
            Set-RunCost 'ollama' $model $usage $s.price
            if ([string]::IsNullOrWhiteSpace($resultJson)) { throw "the model returned no content (finish_reason=$(Get-Prop $choice 'finish_reason'))" }
        }
    }

    $errs = @(Get-SchemaError $resultJson $resultSchemaFile)
    if ($errs.Count -gt 0) { throw "the model output failed $($req.action).result.schema.json: $($errs -join '; ')" }
    $response = [ordered]@{ id = $id; status = 'ok'; action = $req.action; model = $model; result = ($resultJson | ConvertFrom-Json -DateKind String) }
    if ($null -ne $usage) { $response['usage'] = $usage }
    $response['provider'] = $RunProvider
    $response['cost'] = $RunCost
    Write-Response $response
}
catch {
    $msg = "$_"
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg += " | $($_.ErrorDetails.Message)" }
    Write-BridgeLog "error: $msg"
    $response = [ordered]@{ id = $id; status = 'error'; error = $msg }
    if ($RunProvider) { $response['provider'] = $RunProvider }
    if ($RunCost) { $response['cost'] = $RunCost }
    Write-Response $response
}
