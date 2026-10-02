# ==============================================================================
#  lib\realtime_client.ps1
#  Supabase Realtime listener for Mr. Benkhriza
#  Channels:
#    - "deployments"   → new_deployment events (push updates)
#    - "script-updates" → script_submitted / script_approved events
#
#  This runs in a background runspace so it never blocks the WPF UI thread.
#  Call Start-RealtimeListener from the main script after auth succeeds.
# ==============================================================================

param(
    [string]$SupabaseUrl,
    [string]$SupabaseAnonKey,
    [string]$JwtToken,           # user JWT from Supabase Auth
    [string]$CallbackPipeName    # named pipe for posting events back to main process
)

Set-StrictMode -Off
Add-Type -AssemblyName System.Net.WebSockets
Add-Type -AssemblyName System.Threading

# ---------------------------------------------------------------------------
# Named Pipe writer — sends JSON events back to the WPF process
# ---------------------------------------------------------------------------
function Send-Event {
    param([hashtable]$Payload)
    try {
        $json = $Payload | ConvertTo-Json -Compress
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $CallbackPipeName, [System.IO.Pipes.PipeDirection]::Out)
        $pipe.Connect(500)
        $sw   = New-Object System.IO.StreamWriter($pipe)
        $sw.AutoFlush = $true
        $sw.WriteLine($json)
        $sw.Dispose()
        $pipe.Dispose()
    } catch {}
}

# ---------------------------------------------------------------------------
# WebSocket URL (Supabase Realtime v2)
# ---------------------------------------------------------------------------
$wsBase  = $SupabaseUrl -replace '^https://', 'wss://' -replace '^http://', 'ws://'
$wsUrl   = "$wsBase/realtime/v1/websocket?apikey=$SupabaseAnonKey&vsn=1.0.0"

$cts    = New-Object System.Threading.CancellationTokenSource
$token  = $cts.Token
$ws     = New-Object System.Net.WebSockets.ClientWebSocket

$ws.Options.SetRequestHeader("Authorization", "Bearer $JwtToken")

try {
    $connectTask = $ws.ConnectAsync([Uri]$wsUrl, $token)
    $connectTask.Wait(10000, $token) | Out-Null
} catch {
    Send-Event @{ event = "error"; message = "WebSocket connect failed: $_" }
    exit 1
}

Send-Event @{ event = "connected"; message = "Realtime WebSocket connected." }

# ---------------------------------------------------------------------------
# Subscribe to channels  (Realtime v2 Phoenix protocol)
# ---------------------------------------------------------------------------
function Send-PhoenixMsg {
    param([hashtable]$Msg)
    $json  = $Msg | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg   = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).Wait()
}

# Heartbeat ref counter
$global:MsgRef = 1

function Next-Ref { $global:MsgRef++; $global:MsgRef }

# Join "deployments" broadcast channel
Send-PhoenixMsg @{
    topic   = "realtime:deployments"
    event   = "phx_join"
    payload = @{
        config = @{
            broadcast  = @{ self = $false }
            presence   = @{ key = "" }
            postgres_changes = @()
        }
    }
    ref = (Next-Ref)
}

# Join "script-updates" broadcast channel + Postgres Changes on scripts table
Send-PhoenixMsg @{
    topic   = "realtime:script-updates"
    event   = "phx_join"
    payload = @{
        config = @{
            broadcast  = @{ self = $false }
            presence   = @{ key = "" }
            postgres_changes = @(
                @{
                    event  = "UPDATE"
                    schema = "public"
                    table  = "scripts"
                    filter = "status=eq.active"
                }
            )
        }
    }
    ref = (Next-Ref)
}

# ---------------------------------------------------------------------------
# Heartbeat timer (every 25 s to keep connection alive)
# ---------------------------------------------------------------------------
$hbTimer = [System.Timers.Timer]::new(25000)
$hbTimer.AutoReset = $true
$hbTimer.add_Elapsed({
    try {
        Send-PhoenixMsg @{ topic = "phoenix"; event = "heartbeat"; payload = @{}; ref = (Next-Ref) }
    } catch {}
})
$hbTimer.Start()

# ---------------------------------------------------------------------------
# Receive loop
# ---------------------------------------------------------------------------
$buffer = New-Object byte[] 65536

while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and -not $token.IsCancellationRequested) {
    try {
        $result     = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $token)
        $result.Wait()
        $rcv        = $result.Result

        if ($rcv.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            Send-Event @{ event = "disconnected"; message = "Server closed connection." }
            break
        }

        $raw  = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $rcv.Count)
        $msg  = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $msg) { continue }

        # Phoenix heartbeat reply
        if ($msg.event -eq "phx_reply" -and $msg.payload.status -eq "ok") { continue }

        # Broadcast events
        if ($msg.event -eq "broadcast" -and $msg.payload.type -eq "broadcast") {
            $inner = $msg.payload
            switch ($inner.event) {
                "new_deployment" {
                    Send-Event @{
                        event        = "new_deployment"
                        version      = $inner.payload.version
                        changelog    = $inner.payload.changelog
                        download_url = $inner.payload.download_url
                        is_critical  = $inner.payload.is_critical
                        timestamp    = $inner.payload.timestamp
                    }
                }
                "script_submitted" {
                    Send-Event @{
                        event       = "script_submitted"
                        script_id   = $inner.payload.script_id
                        app_id      = $inner.payload.app_id
                        version     = $inner.payload.version
                        sha256      = $inner.payload.sha256
                        github_path = $inner.payload.github_path
                        author_id   = $inner.payload.author_id
                    }
                }
            }
        }

        # Postgres Changes (status → active)
        if ($msg.event -eq "postgres_changes") {
            $record = $msg.payload.record
            Send-Event @{
                event      = "script_activated"
                script_id  = $record.id
                app_id     = $record.app_id
                version    = $record.current_version
                sha256     = $record.current_sha256
                github_path = $record.github_path
            }
        }
    } catch [OperationCanceledException] {
        break
    } catch {
        Send-Event @{ event = "error"; message = "Receive error: $_" }
        Start-Sleep -Milliseconds 2000
    }
}

$hbTimer.Stop()
$hbTimer.Dispose()
try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Closing", $token).Wait(3000) } catch {}
$ws.Dispose()
$cts.Dispose()
Send-Event @{ event = "closed"; message = "Realtime listener stopped." }
