# ==============================================================================
#  lib\lua_sync.ps1
#  Lua Script Sync Module — Mr. Benkhriza v2.2
#
#  Provides:
#    Submit-LuaScript     : Validate + submit via Edge Function (lua-ingest)
#    Start-RealtimeSync   : Launch background listener + named pipe handler
#    Stop-RealtimeSync    : Clean up background listener
#    Invoke-ScriptUpdate  : Download + apply an activated script from GitHub
# ==============================================================================

# ---------------------------------------------------------------------------
# 1. Submit a Lua script to the Edge Function
# ---------------------------------------------------------------------------
function Submit-LuaScript {
    <#
    .SYNOPSIS
        Validates a Lua file locally, then submits it to the lua-ingest Edge Function.
    .PARAMETER AppId
        Steam AppID (e.g. "311210")
    .PARAMETER Title
        Human-readable title (e.g. "Call of Duty: Black Ops 3")
    .PARAMETER LuaFilePath
        Absolute path to the .lua file to submit
    .PARAMETER Message
        Optional commit message
    .OUTPUTS
        PSCustomObject with Success, ScriptId, Version, Sha256, CommitUrl, Error
    #>
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$LuaFilePath,
        [string]$Message    = "",
        [string]$Description = ""
    )

    # --- Local pre-validation ---
    if (-not (Test-Path $LuaFilePath)) {
        return [PSCustomObject]@{ Success = $false; Error = "File not found: $LuaFilePath" }
    }

    $luaBody = Get-Content -LiteralPath $LuaFilePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($luaBody)) {
        return [PSCustomObject]@{ Success = $false; Error = "Lua file is empty." }
    }

    # Must contain addappid
    if ($luaBody -notmatch '\baddappid\s*\(') {
        return [PSCustomObject]@{ Success = $false; Error = "Validation: missing addappid() call." }
    }

    # Basic deny-list (mirrors Edge Function patterns)
    $denyPatterns = @(
        '\bos\s*\.\s*(execute|exit|getenv)\b',
        '\bio\s*\.\s*(open|popen)\b',
        '\bdofile\s*\(',
        '\bloadfile\s*\(',
        '\bload\s*\('
    )
    foreach ($p in $denyPatterns) {
        if ($luaBody -match $p) {
            return [PSCustomObject]@{ Success = $false; Error = "Sandbox violation: forbidden Lua construct detected ($p)." }
        }
    }

    # Compute local SHA-256
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString(
        $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($luaBody))
    ) -replace '-'
    $hash = $hash.ToLower()

    # --- JWT check ---
    $jwt = $global:AppState.SupabaseJWT
    if ([string]::IsNullOrWhiteSpace($jwt)) {
        return [PSCustomObject]@{ Success = $false; Error = "Not authenticated. Log in with Supabase Auth first." }
    }

    $endpoint = "$($global:AppState.SupabaseUrl)/functions/v1/lua-ingest"
    $headers  = @{
        "Authorization" = "Bearer $jwt"
        "Content-Type"  = "application/json"
        "apikey"        = $global:AppState.SupabaseAnonKey
    }
    $bodyObj  = @{
        app_id      = $AppId
        title       = $Title
        body        = $luaBody
        message     = if ($Message) { $Message } else { "Upload $AppId.lua v$(Get-Date -Format 'yyyy-MM-dd')" }
        description = $Description
    }

    try {
        $resp = Invoke-RestMethod `
            -Uri         $endpoint `
            -Method      Post `
            -Headers     $headers `
            -Body        ($bodyObj | ConvertTo-Json -Depth 3) `
            -TimeoutSec  30

        return [PSCustomObject]@{
            Success    = $true
            ScriptId   = $resp.script_id
            Version    = $resp.version
            Sha256     = $resp.sha256
            CommitUrl  = $resp.commit_url
            Remaining  = $resp.rate_limit_remaining
            Message    = $resp.message
            LocalHash  = $hash
        }
    } catch {
        $errBody = ""
        try { $errBody = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { $errBody = $_.Exception.Message }
        return [PSCustomObject]@{ Success = $false; Error = $errBody }
    }
}

# ---------------------------------------------------------------------------
# 2. Start the background Realtime listener
# ---------------------------------------------------------------------------
$global:RealtimeRunspace = $null
$global:RealtimePipe     = $null
$global:RealtimePipeName = "MrBenkhrizaRT_$(Get-Random)"

function Start-RealtimeSync {
    <#
    .SYNOPSIS
        Starts a background STA runspace running realtime_client.ps1.
        Events are posted back via a named pipe and dispatched on the WPF
        dispatcher thread.
    .PARAMETER OnDeployment
        ScriptBlock called when a new_deployment event arrives.
        Receives one argument: hashtable with version, changelog, download_url, is_critical.
    .PARAMETER OnScriptActivated
        ScriptBlock called when a script status changes to active.
        Receives one argument: hashtable with script_id, app_id, version, sha256, github_path.
    #>
    param(
        [scriptblock]$OnDeployment      = {},
        [scriptblock]$OnScriptActivated = {},
        [scriptblock]$OnScriptSubmitted = {}
    )

    if ($global:RealtimeRunspace) { Stop-RealtimeSync }

    $pipeName = $global:RealtimePipeName
    $supaUrl  = $global:AppState.SupabaseUrl
    $anonKey  = $global:AppState.SupabaseAnonKey
    $jwt      = $global:AppState.SupabaseJWT
    $libDir   = $PSScriptRoot

    # Named pipe server (reads events from listener runspace)
    $pipeServer = New-Object System.IO.Pipes.NamedPipeServerStream(
        $pipeName,
        [System.IO.Pipes.PipeDirection]::In,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous
    )
    $global:RealtimePipe = $pipeServer

    # Dispatcher reference for UI thread callbacks
    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher

    # Async pipe read loop
    $pipeReader = [System.IO.StreamReader]::new($pipeServer)
    $readCallback = [System.AsyncCallback]{
        param($ar)
        try {
            # Connect completes — start reading lines
            while ($pipeServer.IsConnected) {
                $line = $pipeReader.ReadLine()
                if ($null -eq $line) { break }
                $ev = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $ev) { continue }

                # Dispatch to WPF thread
                $dispatcher.InvokeAsync({
                    switch ($ev.event) {
                        "new_deployment"   { & $OnDeployment      $ev }
                        "script_activated" { & $OnScriptActivated $ev }
                        "script_submitted" { & $OnScriptSubmitted $ev }
                        "error"            { Add-Log "[REALTIME ERROR] $($ev.message)" "#FF003C" }
                        "connected"        { Add-Log "[REALTIME] Connected to Supabase Realtime." "#00FF41" }
                        "disconnected"     { Add-Log "[REALTIME] Disconnected. Reconnecting in 10s..." "#FF9900" }
                    }
                }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
            }
            # Pipe closed — reset for next client
            if ($pipeServer.IsConnected) { $pipeServer.Disconnect() }
            $pipeServer.BeginWaitForConnection($readCallback, $null)
        } catch {}
    }
    $pipeServer.BeginWaitForConnection($readCallback, $null)

    # Background runspace for the WebSocket listener
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript(". '$libDir\realtime_client.ps1'")
    [void]$ps.AddParameter('SupabaseUrl',      $supaUrl)
    [void]$ps.AddParameter('SupabaseAnonKey',  $anonKey)
    [void]$ps.AddParameter('JwtToken',         $jwt)
    [void]$ps.AddParameter('CallbackPipeName', $pipeName)

    $asyncHandle = $ps.BeginInvoke()

    $global:RealtimeRunspace = [PSCustomObject]@{
        Runspace    = $rs
        PowerShell  = $ps
        AsyncHandle = $asyncHandle
    }

    Add-Log "[REALTIME] Background listener starting..." "#00FF41"
}

# ---------------------------------------------------------------------------
# 3. Stop the Realtime listener
# ---------------------------------------------------------------------------
function Stop-RealtimeSync {
    if ($global:RealtimeRunspace) {
        try {
            $global:RealtimeRunspace.PowerShell.Stop()
            $global:RealtimeRunspace.Runspace.Close()
        } catch {}
        $global:RealtimeRunspace = $null
    }
    if ($global:RealtimePipe) {
        try { $global:RealtimePipe.Dispose() } catch {}
        $global:RealtimePipe = $null
    }
    Add-Log "[REALTIME] Listener stopped." "#FF9900"
}

# ---------------------------------------------------------------------------
# 4. Apply an incoming script update (download from GitHub raw + install)
# ---------------------------------------------------------------------------
function Invoke-ScriptUpdate {
    <#
    .SYNOPSIS
        Downloads the activated Lua script from GitHub raw URL and installs
        it into the local Steam lua folder and the database cache.
    .PARAMETER AppId
        The Steam AppID (filename without .lua extension).
    .PARAMETER GithubPath
        The path inside the repo, e.g. "database/311210.lua".
    .PARAMETER ExpectedSha256
        SHA-256 to verify integrity of the downloaded file.
    #>
    param(
        [string]$AppId,
        [string]$GithubPath,
        [string]$ExpectedSha256
    )

    $rawBase  = "https://raw.githubusercontent.com/$($global:AppState.GitHubOwner)/$($global:AppState.GitHubRepo)/main/$GithubPath"
    $destDb   = Join-Path $global:AppState.DbPath  "$AppId.lua"
    $destSteam= Join-Path $global:AppState.SteamLuaPath "$AppId.lua"

    try {
        $content = Invoke-RestMethod -Uri $rawBase -TimeoutSec 15

        # Integrity check
        $sha     = [System.Security.Cryptography.SHA256]::Create()
        $actual  = ([BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($content))
        ) -replace '-').ToLower()

        if ($actual -ne $ExpectedSha256) {
            Add-Log "[SYNC] INTEGRITY FAIL for $AppId.lua — expected $ExpectedSha256, got $actual" "#FF003C"
            return $false
        }

        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($destDb,    $content, $enc)
        [System.IO.File]::WriteAllText($destSteam, $content, $enc)

        Add-Log "[SYNC] ✔ $AppId.lua updated to verified version (SHA256: $($actual.Substring(0,16))...)" "#00FF41"
        return $true
    } catch {
        Add-Log "[SYNC] Download failed for $AppId.lua : $_" "#FF003C"
        return $false
    }
}
