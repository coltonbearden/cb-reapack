#Requires -Version 7.0
<#
.SYNOPSIS
  Store, check or remove the Anthropic API key the LLM bridge uses for Claude models (D-91).

.DESCRIPTION
  The key is kept encrypted to your Windows user (DPAPI) in the file the bridge config names
  (providers.anthropic.keyFile; by default %LOCALAPPDATA%\reaper-bridge\anthropic.key). bridge.ps1
  reads it on each run that uses a Claude model, and nothing else does. The key is never printed,
  logged or written anywhere else.
  - No switch: asks for the key at a hidden prompt and stores it, replacing a stored key, then
    probes it.
  - -FromStdin: reads the key from standard input instead, for a password manager's command line:
      op read "op://<vault>/<item>/credential" | pwsh -NoProfile -File Set-BridgeKey.ps1 -FromStdin
  - -Status: whether a key is stored, and its kind and length (never the value).
  - -Probe: asks the Claude API's model list with the stored key, which costs nothing, and prints
    the answer's status and the workspace the key belongs to.
  - -Remove: deletes the stored key file. Your key itself stays wherever you keep it.
  A value whose shape is not a Claude Console API key (sk-ant-api03-..., sk-ant-usr-...) is refused
  and nothing is written.

.EXAMPLE
  pwsh -NoProfile -File Set-BridgeKey.ps1
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Prompt')]
param(
    [Parameter(ParameterSetName = 'Stdin', Mandatory)] [switch]$FromStdin,
    [Parameter(ParameterSetName = 'Status', Mandatory)] [switch]$Status,
    [Parameter(ParameterSetName = 'Probe', Mandatory)] [switch]$Probe,
    [Parameter(ParameterSetName = 'Remove', Mandatory)] [switch]$Remove,
    [Parameter(ParameterSetName = 'Prompt')] [Parameter(ParameterSetName = 'Stdin')] [switch]$NoProbe,
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })] [string]$ConfigPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BridgeLib.ps1')

$configFile = Get-BridgeConfigFile $ConfigPath
$config = [System.IO.File]::ReadAllText($configFile) | ConvertFrom-Json -DateKind String
$provider = Get-BridgeProvider $config 'anthropic' (Split-Path -Leaf $configFile)
$file = $provider.keyFile
$purpose = 'anthropic key'

function Write-Probe {
    $key = Read-BridgeSecret $file $purpose
    if ($null -eq $key) { throw "no key is stored at $file" }
    try { $p = Invoke-AnthropicProbe $provider $key } finally { $key = $null }
    "probe    GET $($provider.baseUrl.TrimEnd('/'))/v1/models?limit=1 status=$($p.status) anthropic-workspace-id=$($p.workspace) anthropic-organization-id=$($p.organization) request-id=$($p.request_id)"
    if ($p.status -ne 200) { throw "the probe was answered with $($p.status): the key is stored, but the API did not accept it" }
}

switch ($PSCmdlet.ParameterSetName) {
    'Status' {
        $v = Read-BridgeSecret $file $purpose
        if ($null -eq $v) { "absent   $file"; return }
        $written = (Get-Item -LiteralPath $file).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        "present  $file (written $written, kind $(Get-AnthropicKeyKind $v), length $($v.Length))"
        $v = $null
        return
    }
    'Probe' { Write-Probe; return }
    'Remove' {
        if (-not (Test-Path -LiteralPath $file)) { "absent   $file; nothing to remove"; return }
        if ($PSCmdlet.ShouldProcess($file, 'delete the stored Anthropic API key')) {
            Remove-Item -LiteralPath $file -Force
            "removed  $file"
        }
        return
    }
}

if ($FromStdin) {
    $value = [Console]::In.ReadToEnd()
} else {
    $secure = Read-Host -AsSecureString 'Anthropic API key (input hidden)'
    $value = [System.Net.NetworkCredential]::new('', $secure).Password
}
$value = "$value".Trim()
$kind = Get-AnthropicKeyKind $value
if ($kind -ne 'api-key') {
    $length = $value.Length
    $value = $null
    throw "refused: the value (length $length) is of kind $kind, not a Claude Console API key; nothing was written"
}
if ($PSCmdlet.ShouldProcess($file, 'store the Anthropic API key, encrypted to this Windows user')) {
    $replaced = Test-Path -LiteralPath $file
    Save-BridgeSecret $file $value $purpose
    "stored   $file ($(if ($replaced) { 'replaced the stored key; ' })kind $kind, length $($value.Length))"
}
$value = $null
if (-not $NoProbe -and -not $WhatIfPreference) { Write-Probe }
