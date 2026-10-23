#Requires -Version 7.0
# Functions of the LLM bridge, dot-sourced by bridge.ps1 and Set-BridgeKey.ps1 (and by tools\ in the
# repo): the config's providers and models (D-88), the settings a run gets, the schema sent to the
# Messages API (D-89), the DPAPI-protected secrets (D-91) and the cost of a reply (D-94).
# Nothing here prints a secret; a value read from a secret file goes to the caller only.

$BridgeAnthropicVersion = '2026-10-21'
$BridgeProviders = @('ollama', 'anthropic')

# StrictMode-safe property read: $null when the property is absent.
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# %LOCALAPPDATA%\reaper-bridge, where the job folders, the token and the secrets live.
function Get-BridgeDataDir {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set' }
    Join-Path $env:LOCALAPPDATA 'reaper-bridge'
}

# A file setting: an absolute path as given, a bare name under Get-BridgeDataDir. scripts\lib\bridge.lua
# resolves it the same way.
function Resolve-BridgeFile([string]$Value, [string]$Default) {
    $v = if ($Value) { $Value } else { $Default }
    if ([System.IO.Path]::IsPathFullyQualified($v)) { return $v }
    Join-Path (Get-BridgeDataDir) $v
}

# The config file a run reads (D-73): -ConfigPath when given, else the user's own bridge.config.json
# next to this file, else the shipped example. scripts\lib\bridge.lua picks the same file.
function Get-BridgeConfigFile([string]$ConfigPath) {
    if ($ConfigPath) { return $ConfigPath }
    $own = Join-Path $PSScriptRoot 'bridge.config.json'
    if (Test-Path -LiteralPath $own) { return $own }
    Join-Path $PSScriptRoot 'bridge.config.example.json'
}

# The config's models as { id, provider, entry }: a string is an Ollama model, an object names its
# provider and may carry its own settings (D-88). Without "models" the list is the default model.
function Get-BridgeModels($Config, [string]$ConfigName) {
    $list = Get-Prop $Config 'models'
    if ($null -eq $list) { $list = @($Config.model) }
    @(foreach ($m in @($list)) {
        if ($m -is [string]) { [pscustomobject]@{ id = $m; provider = 'ollama'; entry = $null }; continue }
        $id = "$(Get-Prop $m 'id')"
        if (-not $id) { throw "$ConfigName has a models entry with no 'id'" }
        $provider = "$(Get-Prop $m 'provider')"
        if (-not $provider) { $provider = 'ollama' }
        if ($provider -notin $BridgeProviders) { throw "$ConfigName model '$id' names provider '$provider'; known: $($BridgeProviders -join ', ')" }
        [pscustomobject]@{ id = $id; provider = $provider; entry = $m }
    })
}

# One provider's settings. Ollama: baseUrl (providers.ollama, else the top-level baseUrl of a 0.1.x
# config) and the optional Bearer token file (D-23), sent to Ollama only. Anthropic: baseUrl, the key
# file and an optional workspace id for a key that is not scoped to one workspace.
function Get-BridgeProvider($Config, [string]$Name, [string]$ConfigName) {
    $p = Get-Prop (Get-Prop $Config 'providers') $Name
    switch ($Name) {
        'ollama' {
            $baseUrl = Get-Prop $p 'baseUrl'
            if (-not $baseUrl) { $baseUrl = Get-Prop $Config 'baseUrl' }
            if (-not $baseUrl) { throw "$ConfigName has no 'baseUrl' (top level or providers.ollama)" }
            [pscustomobject]@{ name = 'ollama'; baseUrl = "$baseUrl"; tokenFile = (Resolve-BridgeFile (Get-Prop $p 'tokenFile') 'token') }
        }
        'anthropic' {
            $baseUrl = Get-Prop $p 'baseUrl'
            if (-not $baseUrl) { $baseUrl = 'https://api.anthropic.com' }
            [pscustomobject]@{
                name = 'anthropic'; baseUrl = "$baseUrl"; keyFile = (Resolve-BridgeFile (Get-Prop $p 'keyFile') 'anthropic.key')
                workspaceId = "$(Get-Prop $p 'workspaceId')"
            }
        }
        default { throw "unknown provider '$Name'" }
    }
}

# What one run is sent with. Least to most specific: the config, its actions.<action> entry (D-31),
# the model's entry, that entry's actions.<action>, then the request's options (D-54). Only a model
# on the config's list is accepted from options.
function Resolve-BridgeSettings($Config, [string]$Action, $Options, [string]$ConfigName) {
    $s = [ordered]@{
        model = "$($Config.model)"; provider = 'ollama'; reasoningEffort = (Get-Prop $Config 'reasoningEffort')
        temperature = $Config.temperature; maxTokens = $Config.maxTokens; httpTimeoutSeconds = $Config.httpTimeoutSeconds; price = $null
    }
    $apply = {
        param($From, [string[]]$Keys)
        foreach ($key in $Keys) {
            $value = Get-Prop $From $key
            if ($null -ne $value) { $s[$key] = $value }
        }
    }
    & $apply (Get-Prop (Get-Prop $Config 'actions') $Action) @('temperature', 'maxTokens', 'reasoningEffort')

    $models = Get-BridgeModels $Config $ConfigName
    $optModel = Get-Prop $Options 'model'
    if ($null -ne $optModel) {
        if ($optModel -notin $models.id) { throw "model '$optModel' is not in $ConfigName models ($($models.id -join ', '))" }
        $s.model = "$optModel"
    }
    $m = $models | Where-Object id -EQ $s.model | Select-Object -First 1
    if ($m) {
        $s.provider = $m.provider
        $modelKeys = @('temperature', 'maxTokens', 'reasoningEffort', 'httpTimeoutSeconds', 'price')
        & $apply $m.entry $modelKeys
        & $apply (Get-Prop (Get-Prop $m.entry 'actions') $Action) $modelKeys
    }
    $optEffort = Get-Prop $Options 'reasoningEffort'
    if ($null -ne $optEffort) { $s.reasoningEffort = $optEffort }
    [pscustomobject]$s
}

# The result schema as the Messages API takes it (D-89). Structured outputs refuse numeric and string
# bounds, maxItems and a minItems above 1 with a 400, so they are dropped here and written into the
# description instead; bridge.ps1 still checks the answer against the full schema.
$AnthropicDropped = [ordered]@{
    minimum = 'minimum {0}'; maximum = 'maximum {0}'; exclusiveMinimum = 'greater than {0}'; exclusiveMaximum = 'less than {0}'
    multipleOf = 'a multiple of {0}'; minLength = 'at least {0} characters'; maxLength = 'at most {0} characters'
    maxItems = 'at most {0} items'; minItems = 'at least {0} items'
}
function ConvertTo-AnthropicSchema($Schema) {
    if ($Schema -isnot [System.Collections.IDictionary]) { return $Schema }
    $out = [ordered]@{}
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($Schema.Keys)) {
        $value = $Schema[$key]
        if ($key -in '$schema', '$comment') { continue }
        if ($AnthropicDropped.Contains($key) -and -not ($key -eq 'minItems' -and $value -le 1)) {
            $notes.Add($(if ($key -eq 'minLength' -and $value -eq 1) { 'not empty' } else { $AnthropicDropped[$key] -f $value }))
            continue
        }
        # Assigned directly, not through the pipeline, so a one-element array stays an array.
        if ($key -in 'properties', '$defs', 'definitions') {
            $map = [ordered]@{}
            foreach ($name in @($value.Keys)) { $map[$name] = ConvertTo-AnthropicSchema $value[$name] }
            $out[$key] = $map
        } elseif ($key -in 'items', 'not', 'additionalProperties') {
            $out[$key] = ConvertTo-AnthropicSchema $value
        } elseif ($key -in 'anyOf', 'allOf', 'oneOf') {
            $out[$key] = @(foreach ($sub in $value) { ConvertTo-AnthropicSchema $sub })
        } else {
            $out[$key] = $value
        }
    }
    if ($notes.Count -gt 0) {
        $text = $notes -join ', '
        $out['description'] = if ($out.Contains('description')) { "$($out['description']) ($text)" } else { $text }
    }
    $out
}

# A Messages API request body: the prompt as system, the same user text Ollama gets, the effort
# (D-90) and the derived schema. No temperature: API 2026-10-21 refuses it.
function New-AnthropicBody($Settings, [string]$System, [string]$User, $Schema) {
    $output = [ordered]@{}
    if ($Settings.reasoningEffort) { $output['effort'] = $Settings.reasoningEffort }
    $output['format'] = [ordered]@{ type = 'json_schema'; schema = (ConvertTo-AnthropicSchema $Schema) }
    [ordered]@{
        model = $Settings.model; max_tokens = $Settings.maxTokens; system = $System
        messages = @(@{ role = 'user'; content = $User }); output_config = $output
    }
}

# The parts of a Messages API reply the bridge uses: the text blocks joined (thinking blocks come
# first and are skipped), stop_reason, the refusal category, the model and the usage.
function Read-AnthropicReply($Reply) {
    $text = -join @(foreach ($b in @(Get-Prop $Reply 'content')) { if ((Get-Prop $b 'type') -eq 'text') { "$(Get-Prop $b 'text')" } })
    [pscustomobject]@{
        text = $text; stop_reason = "$(Get-Prop $Reply 'stop_reason')"
        category = "$(Get-Prop (Get-Prop $Reply 'stop_details') 'category')"
        model = "$(Get-Prop $Reply 'model')"; usage = (Get-Prop $Reply 'usage')
    }
}

# Why a Messages API reply cannot be used, or $null when it can.
function Get-AnthropicReplyProblem($Parsed, $Settings, [string]$ConfigName) {
    switch ($Parsed.stop_reason) {
        'refusal' { return "Claude declined to answer (refusal$(if ($Parsed.category) { ", category $($Parsed.category)" })); nothing was changed" }
        'max_tokens' { return "the answer was cut off at max_tokens $($Settings.maxTokens) (thinking counts too); raise maxTokens for $($Settings.model) in $ConfigName" }
    }
    if ([string]::IsNullOrWhiteSpace($Parsed.text)) { return "the model returned no text (stop_reason=$($Parsed.stop_reason))" }
    $null
}

# Tokens and an estimated cost in USD (D-94): usage times the model's price per million tokens, from
# its config entry. Ollama runs on our own hardware and costs 0 unless a price is set; any other
# provider without a price has usd $null. Cache tokens are counted at the input price.
function Get-BridgeCost([string]$Provider, $Usage, $Price) {
    if ($Provider -eq 'anthropic') {
        $in = [long](Get-Prop $Usage 'input_tokens') + [long](Get-Prop $Usage 'cache_creation_input_tokens') + [long](Get-Prop $Usage 'cache_read_input_tokens')
        $out = [long](Get-Prop $Usage 'output_tokens')
    } else {
        $in = [long](Get-Prop $Usage 'prompt_tokens')
        $out = [long](Get-Prop $Usage 'completion_tokens')
    }
    $inPrice = Get-Prop $Price 'inputPerMTok'
    $outPrice = Get-Prop $Price 'outputPerMTok'
    $usd = if ($null -ne $inPrice -and $null -ne $outPrice) {
        [math]::Round(($in * [double]$inPrice + $out * [double]$outPrice) / 1e6, 6)
    } elseif ($Provider -eq 'ollama') { 0 } else { $null }
    $priceOut = if ($null -ne $inPrice -and $null -ne $outPrice) { [ordered]@{ inputPerMTok = [double]$inPrice; outputPerMTok = [double]$outPrice } } else { $null }
    [ordered]@{ input_tokens = $in; output_tokens = $out; usd = $usd; price = $priceOut }
}

# ---- secrets (D-91) ---------------------------------------------------------------------------------
# A secret is stored encrypted to the Windows user with DPAPI (CurrentUser scope), with entropy that
# names its purpose, so a blob made for one purpose does not decrypt as another.
function Get-BridgeEntropy([string]$Purpose) { [System.Text.Encoding]::UTF8.GetBytes("cb-bridge $Purpose v1") }

function Save-BridgeSecret([string]$Path, [string]$Value, [string]$Purpose) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $blob = [System.Security.Cryptography.ProtectedData]::Protect($bytes, (Get-BridgeEntropy $Purpose), [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    [System.IO.File]::WriteAllBytes("$Path.tmp", $blob)
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}

# The secret in $Path, or $null when there is no such file.
function Read-BridgeSecret([string]$Path, [string]$Purpose) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $blob = [System.IO.File]::ReadAllBytes($Path)
    try {
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($blob, (Get-BridgeEntropy $Purpose), [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch {
        throw "cannot decrypt $Path as the $Purpose of this Windows user: $($_.Exception.Message)"
    }
    try { [System.Text.Encoding]::UTF8.GetString($bytes) } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

# The kind of a value, read from its shape only, so a wrong paste is named without being shown:
# api-key is one unbroken token with a Claude Console API key's prefix.
function Get-AnthropicKeyKind([string]$Value) {
    if ($Value -cmatch '^sk-ant-(api03|usr)-[A-Za-z0-9_-]+$') { return 'api-key' }
    if ($Value -cmatch '^sk-ant-admin') { return 'admin-key' }
    if ($Value -cmatch '^sk-ant-oat') { return 'oauth-token' }
    if ($Value -cmatch '^sk-ant-') { return 'other-anthropic' }
    'not-anthropic-shaped'
}

# Asks the Messages API's model list with $Key (free; nothing is generated) and returns the status
# and the headers that say which organisation and workspace the key resolved to.
function Invoke-AnthropicProbe($Provider, [string]$Key) {
    $headers = @{ 'x-api-key' = $Key; 'anthropic-version' = $BridgeAnthropicVersion }
    if ($Provider.workspaceId) { $headers['anthropic-workspace-id'] = $Provider.workspaceId }
    $r = Invoke-WebRequest -Uri ($Provider.baseUrl.TrimEnd('/') + '/v1/models?limit=1') -Headers $headers -TimeoutSec 30 -SkipHttpErrorCheck
    $h = { param($n) $v = $r.Headers[$n]; if ($v) { "$(@($v)[0])" } else { 'absent' } }
    [pscustomobject]@{
        status = [int]$r.StatusCode; workspace = (& $h 'anthropic-workspace-id')
        organization = (& $h 'anthropic-organization-id'); request_id = (& $h 'request-id')
    }
}
