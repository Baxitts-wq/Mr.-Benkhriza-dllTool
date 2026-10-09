# ==============================================================================
#  [ SYSTEM LOADER ]: BENKHRIZA STEAM CONTROL SYSTEM
#  VERSION: 2.1.0
#  AUTHOR: Benkhriza
# ==============================================================================
#
#  HOW LUA FILES WORK (for your knowledge):
#  -----------------------------------------
#  Steam splits every game into "depots" - the main exe, DLC content,
#  language packs, etc. Each depot has a unique AES-256 decryption key.
#
#  When you legitimately buy a game, Steam's servers send your client
#  those depot keys. The LUA file is simply a list of addappid() calls:
#
#      addappid(1091500, 1, "cf941dce25dfe...")
#               ^ AppID   ^  ^ depot decryption key (AES-256, hex)
#                         1 = unlock
#
#  Sites like openlua.cloud collect those keys from legit game owners
#  and build a database. This tool lets you manage those LUAs offline.
#
#  DESIGN PRINCIPLES:
#   1. XAML design in external file / logic in this controller
#   2. Shared utility functions - no repeated code
#   3. Persistent disk logging
#   4. External JSON config - no hardcoded settings
#   5. Steam Store online search (public API, no key required)
#   6. Backup sync from GitHub repository
#   7. Security auditing on all file imports
# ==============================================================================

# ------------------------------------------------------------------------------
#  1. Thread Model - STA required for WPF
# ------------------------------------------------------------------------------
try {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        [System.Threading.Thread]::CurrentThread.SetApartmentState([System.Threading.ApartmentState]::STA)
    }
} catch {}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Security

if ($null -eq $global:TestOnly) {
    $global:TestOnly = $false
}

$global:CrashLogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mr_Benkhriza_crash.txt'
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($src, $ev)
    try {
        $msg = "UNHANDLED EXCEPTION $(Get-Date)`r`n$($ev.ExceptionObject)`r`n"
        [System.IO.File]::AppendAllText($global:CrashLogPath, $msg)
    } catch {}
})

# ------------------------------------------------------------------------------
#  2. State & Configuration
# ------------------------------------------------------------------------------
$global:AppState = [PSCustomObject]@{
    Version          = "2.4.0"
    ConfigPath       = Join-Path $PSScriptRoot "mr_benkhriza_gui.json"
    XamlPath         = Join-Path $PSScriptRoot "Mr. Benkhriza.xaml"
    DbPath           = Join-Path $PSScriptRoot "database"
    Window           = $null
    SteamRoot        = $null
    SteamLuaPath     = $null
    LogFilePath      = $null
    LogoBase64       = $null
    BackupUrl        = $null
    GithubToken      = $null
    LocalRepoPath    = $null
    AdminPassword    = $null
    LicenseServerUrl = $null
    HWID             = $null
    Theme            = $null
    Controls         = @{}
    Timers           = @{}
}

$defaultConfig = @{
    Version          = $global:AppState.Version
    SteamPath        = ""
    LogFile          = ""
    BackupUrl        = "https://raw.githubusercontent.com/Baxitts-wq/Mr.-Benkhriza-Lua-dllTool/main/gui/database/"
    GithubToken      = ""
    LocalRepoPath    = ""
    AdminPassword    = "Imad.993514"
    LicenseServerUrl = "http://192.168.129.130:8080"
    Theme = @{
        AccentGreen  = "#00FF41"
        AccentRed    = "#FF003C"
        AccentOrange = "#FF9900"
        BgTerminal   = "#0A0000"
        BgPanel      = "#0A0A0F"
    }
}

if (Test-Path $global:AppState.ConfigPath) {
    try {
        $loaded = Get-Content $global:AppState.ConfigPath -Raw | ConvertFrom-Json
        $global:AppState.Theme         = $loaded.Theme
        $global:AppState.SteamRoot     = $loaded.SteamPath
        $global:AppState.LogFilePath   = $loaded.LogFile
        $global:AppState.BackupUrl     = $loaded.BackupUrl
        $global:AppState.GithubToken   = if ($loaded.GithubToken)   { $loaded.GithubToken }   else { "" }
        $global:AppState.LocalRepoPath = if ($loaded.LocalRepoPath) { $loaded.LocalRepoPath } else { "" }
        $global:AppState.AdminPassword    = if ($loaded.AdminPassword) { $loaded.AdminPassword } else { "BENKHRIZA-ADMIN-2026" }
        $global:AppState.LicenseServerUrl = if ($loaded.LicenseServerUrl) { $loaded.LicenseServerUrl } else { "https://appreciation-dec-known-vessel.trycloudflare.com" }
    } catch {
        $global:AppState.Theme         = $defaultConfig.Theme
        $global:AppState.BackupUrl     = $defaultConfig.BackupUrl
        $global:AppState.GithubToken   = $defaultConfig.GithubToken
        $global:AppState.LocalRepoPath = $defaultConfig.LocalRepoPath
        $global:AppState.AdminPassword    = $defaultConfig.AdminPassword
        $global:AppState.LicenseServerUrl = $defaultConfig.LicenseServerUrl
    }
} else {
    $defaultConfig | ConvertTo-Json -Depth 4 | Out-File $global:AppState.ConfigPath -Encoding utf8
    $global:AppState.Theme         = $defaultConfig.Theme
    $global:AppState.BackupUrl     = $defaultConfig.BackupUrl
    $global:AppState.GithubToken   = $defaultConfig.GithubToken
    $global:AppState.LocalRepoPath = $defaultConfig.LocalRepoPath
    $global:AppState.AdminPassword    = $defaultConfig.AdminPassword
    $global:AppState.LicenseServerUrl = $defaultConfig.LicenseServerUrl
}

# --- DPAPI license key storage & cryptographic lease (machine-bound, tamper-resistant) ---
function Get-AuthFilePath {
    $dir = [System.IO.Path]::Combine($env:APPDATA, "MrBenkhriza")
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return [System.IO.Path]::Combine($dir, ".auth.dat")
}

function Get-LicenseHMAC {
    param([string]$Key, [string]$HWID)
    $salt = "MB-BENKHRIZA-SECURITY-OFFLINE-SALT-v3.0#2026!SECRET"
    $raw = "$($Key.Trim().ToUpper())|$($HWID.Trim().ToUpper())|$salt"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $hash = $sha.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-').Substring(0, 32)
}

function Save-LicenseAuthRecord {
    param(
        [string]$Key,
        [bool]$OnlineVerified = $false
    )
    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    try {
        $myHWID = Get-SystemHWID
        $sig = Get-LicenseHMAC -Key $Key -HWID $myHWID
        $record = [ordered]@{
            Key                 = $Key.Trim()
            HWID                = $myHWID
            MachineName         = $env:COMPUTERNAME
            Signature           = $sig
            FirstActivated      = (Get-Date).ToString("o")
            LastVerified        = (Get-Date).ToString("o")
            OnlineVerified      = $OnlineVerified
            Version             = "3.0"
        }
        $json = $record | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $entropy = [System.Text.Encoding]::UTF8.GetBytes("MrBenkhrizaSecurityEntropy2026")
        $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [System.IO.File]::WriteAllBytes((Get-AuthFilePath), $encrypted)
        return $true
    } catch {
        return $false
    }
}

function Load-LicenseAuthRecord {
    $path = Get-AuthFilePath
    if (-not (Test-Path $path)) { return $null }
    try {
        $encrypted = [System.IO.File]::ReadAllBytes($path)
        $entropy = [System.Text.Encoding]::UTF8.GetBytes("MrBenkhrizaSecurityEntropy2026")
        $decrypted = $null
        try {
            $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $encrypted, $entropy,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
        } catch {
            # Backward compatibility with legacy plain .auth.dat without entropy
            try {
                $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $encrypted, $null,
                    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
                )
            } catch { return $null }
        }
        if (-not $decrypted) { return $null }
        $text = [System.Text.Encoding]::UTF8.GetString($decrypted).Trim()

        if ($text.StartsWith("{") -and $text.EndsWith("}")) {
            $obj = $text | ConvertFrom-Json
            $myHWID = Get-SystemHWID
            $expectedSig = Get-LicenseHMAC -Key $obj.Key -HWID $obj.HWID
            if ($obj.HWID -eq $myHWID -and $obj.Signature -eq $expectedSig) {
                return $obj
            } else {
                return [PSCustomObject]@{
                    Tampered    = $true
                    BoundHWID   = $obj.HWID
                    CurrentHWID = $myHWID
                    Key         = $obj.Key
                }
            }
        } else {
            # Legacy plain key string - auto-upgrade to modern signed record
            $legacyKey = $text.Trim()
            if ($legacyKey.Length -ge 8) {
                Save-LicenseAuthRecord -Key $legacyKey -OnlineVerified $false | Out-Null
                return (Load-LicenseAuthRecord)
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Save-LicenseKey {
    param([string]$Key)
    return (Save-LicenseAuthRecord -Key $Key -OnlineVerified $false)
}

function Load-LicenseKey {
    # 1. First, check valid machine-bound DPAPI lease
    $record = Load-LicenseAuthRecord
    if ($record -and -not $record.Tampered -and $record.Key) {
        return $record.Key
    }

    # 2. Local license.key file next to script
    if ($global:AppState -and $global:AppState.ScriptDir) {
        $keyFile = Join-Path $global:AppState.ScriptDir "license.key"
        if (Test-Path $keyFile) {
            try {
                $raw = (Get-Content -Path $keyFile -Raw -Encoding utf8).Trim()
                if ($raw -and -not $raw.StartsWith("#") -and $raw.Length -ge 8) {
                    return $raw
                }
            } catch {}
        }
    }

    # 3. Local mr_benkhriza_gui.json if LicenseKey is filled
    if ($global:AppState -and $global:AppState.ConfigPath -and (Test-Path $global:AppState.ConfigPath)) {
        try {
            $j = Get-Content $global:AppState.ConfigPath -Raw | ConvertFrom-Json
            if ($j.LicenseKey -and -not [string]::IsNullOrWhiteSpace($j.LicenseKey) -and $j.LicenseKey.Trim().Length -ge 8) {
                return $j.LicenseKey.Trim()
            }
        } catch {}
    }

    return $null
}

if (-not $global:AppState.SteamRoot) {
    try {
        $rv = Get-ItemPropertyValue 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction Stop
        $global:AppState.SteamRoot = $rv -replace '/', '\'
    } catch {
        $global:AppState.SteamRoot = ""
    }
}

if (-not $global:AppState.SteamRoot -or -not (Test-Path (Join-Path $global:AppState.SteamRoot 'steam.exe'))) {
    $candidatePaths = @()
    if ($env:ProgramFiles -and (Test-Path (Join-Path $env:ProgramFiles 'Steam\steam.exe'))) {
        $candidatePaths += Join-Path $env:ProgramFiles 'Steam'
    }
    $progFilesX86 = ${env:ProgramFiles(x86)}
    if ($progFilesX86 -and (Test-Path (Join-Path $progFilesX86 'Steam\steam.exe'))) {
        $candidatePaths += Join-Path $progFilesX86 'Steam'
    }
    if ($env:LOCALAPPDATA -and (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\Steam\steam.exe'))) {
        $candidatePaths += Join-Path $env:LOCALAPPDATA 'Programs\Steam'
    }
    if ($candidatePaths.Count -gt 0) {
        $global:AppState.SteamRoot = $candidatePaths[0]
    }
}

if (-not $global:AppState.SteamRoot) {
    $global:AppState.SteamRoot = "C:\Program Files (x86)\Steam"
}

$global:AppState.SteamLuaPath = Join-Path $global:AppState.SteamRoot "config\lua"
if (-not (Test-Path $global:AppState.SteamLuaPath)) {
    try { New-Item -ItemType Directory -Path $global:AppState.SteamLuaPath -Force | Out-Null } catch {}
}

# --- Auto-Setup: Automatically ensure SteamFiles & configs are present in Steam ---
function Initialize-SteamEnvironment {
    param([string]$SteamPath = $global:AppState.SteamRoot)
    if ([string]::IsNullOrWhiteSpace($SteamPath)) { return }
    if (-not (Test-Path $SteamPath)) {
        try { New-Item -ItemType Directory -Path $SteamPath -Force | Out-Null } catch {}
    }
    $luaDir = Join-Path $SteamPath "config\lua"
    if (-not (Test-Path $luaDir)) {
        try { New-Item -ItemType Directory -Path $luaDir -Force | Out-Null } catch {}
    }

    $sfDir = Join-Path $PSScriptRoot "SteamFiles"
    if (Test-Path $sfDir) {
        $requiredFiles = @("OpenSteamTool.dll", "dwmapi.dll", "xinput1_4.dll", "opensteamtool.toml")
        $deployed = 0
        foreach ($rf in $requiredFiles) {
            $srcFile = Join-Path $sfDir $rf
            $dstFile = Join-Path $SteamPath $rf
            if ((Test-Path $srcFile) -and (-not (Test-Path $dstFile))) {
                try {
                    Copy-Item -Path $srcFile -Destination $dstFile -Force -ErrorAction SilentlyContinue
                    $deployed++
                } catch {}
            }
        }
        if ($deployed -gt 0) {
            Add-Log "[*] [AUTO-SETUP] $deployed composant(s) Steam deployes automatiquement dans $SteamPath" "#00FF00"
        }
    }

    $manifestDst = Join-Path $luaDir "manifest.lua"
    if (-not (Test-Path $manifestDst)) {
        $manifestSrc = Join-Path $sfDir "config\lua\manifest.lua"
        if (Test-Path $manifestSrc) {
            try { Copy-Item -Path $manifestSrc -Destination $manifestDst -Force -ErrorAction SilentlyContinue } catch {}
        } else {
            @'
-- manifest.lua -- Auto-generated
function fetch_manifest_code(gid)
    local body, st = http_get("https://manifest.steam.run/api/manifest/" .. gid)
    if st == 200 and body then
        local code = body:match('"content":"(%d+)"')
        if code then return code end
    end
    return nil
end
'@ | Out-File -FilePath $manifestDst -Encoding UTF8 -Force
        }
    }

    $mygamesDst = Join-Path $luaDir "mygames.lua"
    if (-not (Test-Path $mygamesDst)) {
        try {
            "-- mygames.lua -- Auto-managed by Mr. Benkhriza" | Out-File -FilePath $mygamesDst -Encoding UTF8 -Force
        } catch {}
    }
}

try { Initialize-SteamEnvironment } catch {}

if (-not $global:AppState.LogFilePath) {
    $global:AppState.LogFilePath = Join-Path $global:AppState.SteamRoot "opensteamtool\mr_benkhriza.log"
}
$logDir = [System.IO.Path]::GetDirectoryName($global:AppState.LogFilePath)
if (-not (Test-Path $logDir)) { try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch {} }

$logoPath = Join-Path $PSScriptRoot "Mr_Benkhriza_Logo.png"
if (Test-Path $logoPath) {
    try { $global:AppState.LogoBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($logoPath)) } catch {}
}

# ------------------------------------------------------------------------------
#  3. Utility Functions & Security Authentication Engine
# ------------------------------------------------------------------------------
function Get-SystemHWID {
    try {
        $uuid = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
        $cpu  = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).ProcessorId
        $mb   = (Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue).SerialNumber
        $combined = "$uuid|$cpu|$mb"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
        $hashBytes = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes) -replace '-').Substring(0, 32)
    } catch {
        return "HWID_$(($env:COMPUTERNAME -replace '[^a-zA-Z0-9]', ''))"
    }
}

function Get-PublicIP {
    try {
        $ip = Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 4
        return $ip.Trim()
    } catch {
        return "Unknown/Offline"
    }
}

function Get-LicenseServerCandidates {
    $candidates = [System.Collections.Generic.List[string]]::new()

    # 1. Configured URL if already a public HTTPS URL (not local LAN)
    $cfgUrl = if ($global:AppState -and $global:AppState.LicenseServerUrl) { $global:AppState.LicenseServerUrl.Trim().TrimEnd('/') } else { "" }
    if ($cfgUrl -and $cfgUrl -match '^https://') {
        $candidates.Add($cfgUrl)
    }

    # 2. Realtime dynamic discovery from Ntfy (updated live by PC2 tunnel daemon, sub-300ms)
    try {
        $resp = Invoke-RestMethod -Uri 'https://ntfy.sh/bexytv-internal-url-998877/json?poll=1' -TimeoutSec 3
        $respText = [string]$resp
        $allMatches = [regex]::Matches($respText, 'https://[a-zA-Z0-9\-]+\.trycloudflare\.com')
        if ($allMatches.Count -gt 0) {
            $latestUrl = $allMatches[$allMatches.Count - 1].Value
            $candidates.Add($latestUrl)
        }
    } catch {}

    # 3. Permanent GitHub Raw resolver from repository
    try {
        $ghRaw = (Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Baxitts-wq/Mr.-Benkhriza-dllTool/main/server_url.txt' -TimeoutSec 3).Trim()
        if ($ghRaw -match '^https?://[a-zA-Z0-9\.\-]+') {
            $candidates.Add($ghRaw.TrimEnd('/'))
        }
    } catch {}

    # 4. Known active Cloudflare tunnel
    $candidates.Add("https://appreciation-dec-known-vessel.trycloudflare.com")

    # 5. Local LAN IP as final fallback (for local Wi-Fi dev)
    if ($cfgUrl -and $cfgUrl -notmatch '^https://') {
        $candidates.Add($cfgUrl)
    }
    $candidates.Add("http://192.168.129.130:8080")

    return @($candidates | Select-Object -Unique)
}

function Test-SupabaseLicense {
    param(
        [string]$LicenseKey,
        [switch]$AllowOfflineFallback
    )

    if ([string]::IsNullOrWhiteSpace($LicenseKey)) {
        return [PSCustomObject]@{ Success = $false; Mode = "MissingKey"; Message = "No license key provided."; HWID = (Get-SystemHWID) }
    }

    $myHWID = Get-SystemHWID
    $body = @{
        license_key = $LicenseKey
        hwid        = $myHWID
    } | ConvertTo-Json

    $candidates = Get-LicenseServerCandidates
    $lastError = "No connection possible to authentication server."

    # When offline fallback is allowed (already bound locally), use strict short timeout (2s)
    $timeoutSec = if ($AllowOfflineFallback) { 2 } else { 3 }

    foreach ($serverUrl in $candidates) {
        if ([string]::IsNullOrWhiteSpace($serverUrl)) { continue }
        $apiUrl = "$($serverUrl.TrimEnd('/'))/api/license/verify"
        try {
            $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $body -ContentType "application/json" -TimeoutSec $timeoutSec
            if ($response) {
                # Success reaching server - cache this working server URL in AppState
                if ($global:AppState) { $global:AppState.LicenseServerUrl = $serverUrl }

                return [PSCustomObject]@{
                    Success   = [bool]$response.success
                    Mode      = $response.mode
                    Message   = $response.message
                    HWID      = $myHWID
                    BoundHWID = $response.bound_hwid
                }
            }
        } catch {
            $lastError = $_.Exception.Message
            continue
        }
    }

    # If server unreachable and offline fallback is allowed:
    if ($AllowOfflineFallback) {
        return [PSCustomObject]@{
            Success   = $true
            Mode      = "OfflineVerified"
            Message   = "Serveur hors ligne. Matériel HWID vérifié localement (Mode Hors Ligne)."
            HWID      = $myHWID
        }
    }

    return [PSCustomObject]@{
        Success = $false
        Mode    = "ServerError"
        Message = "Auth server error: $lastError"
        HWID    = $myHWID
    }
}

function Show-LicenseEntryDialog {
    # Dark WPF dialog to capture the license key on first run
    $dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mr. Benkhriza Ã¢â‚¬â€ License Activation" Height="280" Width="500"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#0A0A0F" Topmost="True">
    <Grid Margin="30">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="LICENSE ACTIVATION" FontFamily="Consolas" FontSize="16"
                   Foreground="#00FF41" FontWeight="Bold" Margin="0,0,0,10"/>
        <TextBlock Grid.Row="1" Text="Enter your license key to activate Mr. Benkhriza on this machine.
Your key will be encrypted and bound to this PC's hardware ID." 
                   FontFamily="Consolas" FontSize="11" Foreground="#AAAAAA" TextWrapping="Wrap" Margin="0,0,0,18"/>
        <TextBox Grid.Row="2" x:Name="KeyBox" FontFamily="Consolas" FontSize="13"
                 Background="#111120" Foreground="#00FF41" BorderBrush="#00FF41" 
                 BorderThickness="1" Padding="8,6" Margin="0,0,0,10"
                 CaretBrush="#00FF41"/>
        <TextBlock Grid.Row="3" x:Name="StatusText" FontFamily="Consolas" FontSize="11"
                   Foreground="#FF003C" Text="" Margin="0,0,0,10" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
            <Button x:Name="ActivateBtn" Content="[ ACTIVATE ]" FontFamily="Consolas" FontSize="12"
                    Background="#00FF41" Foreground="#000000" FontWeight="Bold"
                    BorderThickness="0" Padding="16,8" Margin="0,0,10,0" Cursor="Hand"/>
            <Button x:Name="CancelBtn" Content="[ CANCEL ]" FontFamily="Consolas" FontSize="12"
                    Background="#1A1A2E" Foreground="#FF003C" FontWeight="Bold"
                    BorderBrush="#FF003C" BorderThickness="1" Padding="16,8" Cursor="Hand"/>
        </StackPanel>
    </Grid>
</Window>
"@
    try {
        $reader   = New-Object System.Xml.XmlNodeReader([xml]$dialogXaml)
        $dlg      = [System.Windows.Markup.XamlReader]::Load($reader)
        $keyBox   = $dlg.FindName("KeyBox")
        $statusTb = $dlg.FindName("StatusText")
        $actBtn   = $dlg.FindName("ActivateBtn")
        $canBtn   = $dlg.FindName("CancelBtn")

        $result   = [PSCustomObject]@{ Key = $null; Activated = $false }

        $actBtn.Add_Click({
            $k = $keyBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($k)) {
                $statusTb.Foreground = [System.Windows.Media.Brushes]::Red
                $statusTb.Text = "Please enter a key."
                return
            }
            $statusTb.Foreground = [System.Windows.Media.Brushes]::Yellow
            $statusTb.Text = "Validating..."

            $authResult = Test-SupabaseLicense -LicenseKey $k
            if ($authResult.Success) {
                Save-LicenseAuthRecord -Key $k -OnlineVerified $true | Out-Null
                $result.Key = $k
                $result.Activated = $true
                $dlg.DialogResult = $true
                $dlg.Close()
            } elseif ($authResult.Mode -eq "ServerError") {
                # Server is offline / unreachable during activation
                # Check if this key matches genuine product key format
                if ($k -match '^MB-KEY-[A-Z0-9\-]{8,}$') {
                    Save-LicenseAuthRecord -Key $k -OnlineVerified $false | Out-Null
                    $result.Key = $k
                    $result.Activated = $true
                    [System.Windows.MessageBox]::Show(
                        "Serveur d'authentification temporairement hors ligne.`n`nActivation hors ligne réussie ! La licence a été liée à cet ordinateur (HWID crypté).`nSynchronisation automatique lors de la prochaine connexion.",
                        "Mr. Benkhriza - Mode Hors Ligne",
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Information
                    ) | Out-Null
                    $dlg.DialogResult = $true
                    $dlg.Close()
                } else {
                    $statusTb.Foreground = [System.Windows.Media.Brushes]::Red
                    $statusTb.Text = "Serveur hors ligne & format de clé invalide. Format requis: MB-KEY-XXXX-XXXX."
                }
            } else {
                $statusTb.Foreground = [System.Windows.Media.Brushes]::Red
                $statusTb.Text = $authResult.Message
            }
        })

        $canBtn.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
        $dlg.ShowDialog() | Out-Null
        return $result
    } catch {
        [System.Windows.MessageBox]::Show("Activation Dialog Error:`n$($_.Exception.Message)", "Mr. Benkhriza - Error", 0, 16) | Out-Null
        return [PSCustomObject]@{ Key = $null; Activated = $false }
    }
}
function Get-SolidBrush {
    param([string]$hex)
    try {
        $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
        return New-Object System.Windows.Media.SolidColorBrush($c)
    } catch {
        return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Green)
    }
}

function Add-Log {
    param([string]$Text, [string]$Color = "#00FF00")
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
    $tb.FontSize  = 11
    $tb.Margin    = "0,1"
    $tb.Foreground = Get-SolidBrush $Color
    $tb.Text      = $Text
    if ($global:AppState.Controls.LogPanel)  { $global:AppState.Controls.LogPanel.Children.Add($tb) | Out-Null }
    if ($global:AppState.Controls.LogScroll) { $global:AppState.Controls.LogScroll.ScrollToEnd() }
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        "[$ts] $Text" | Out-File -FilePath $global:AppState.LogFilePath -Append -Encoding utf8
    } catch {}
}

function Add-TypewriterLog {
    param(
        [string]$Text,
        [string]$Color = "#00FF00",
        [int]$CharDelayMs = 20,
        [scriptblock]$OnComplete = $null
    )
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
    $tb.FontSize  = 11
    $tb.Margin    = "0,1"
    $tb.Foreground = Get-SolidBrush $Color
    $tb.Text      = ""
    if ($global:AppState.Controls.LogPanel) { $global:AppState.Controls.LogPanel.Children.Add($tb) | Out-Null }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($CharDelayMs)

    $hash = $timer.GetHashCode()
    $global:AppState.Timers["Timer_$hash"] = @{
        Text = $Text
        TextBlock = $tb
        Index = 0
        OnComplete = $OnComplete
    }

    $timer.Add_Tick({
        param($sender, $e)
        $h = $sender.GetHashCode()
        $data = $global:AppState.Timers["Timer_$h"]
        if ($data.Index -lt $data.Text.Length) {
            $data.TextBlock.Text += $data.Text[$data.Index]
            $data.Index++
            Play-TypewriterTick
            if ($global:AppState.Controls.LogScroll) { $global:AppState.Controls.LogScroll.ScrollToEnd() }
        } else {
            $sender.Stop()
            $global:AppState.Timers.Remove("Timer_$h") | Out-Null
            if ($data.OnComplete) { & $data.OnComplete }
        }
    })
    $timer.Start()
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        "[$ts] $Text" | Out-File -FilePath $global:AppState.LogFilePath -Append -Encoding utf8
    } catch {}
}

function Add-TypewriterLogToElement {
    param(
        [System.Windows.Controls.TextBlock]$TargetElement,
        [string]$Text,
        [int]$CharDelayMs = 25,
        [scriptblock]$OnComplete = $null
    )
    if (-not $TargetElement) { if ($OnComplete) { & $OnComplete }; return }
    $TargetElement.Text = ""
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($CharDelayMs)

    $hash = $timer.GetHashCode()
    $global:AppState.Timers["Timer_$hash"] = @{
        Text = $Text
        Target = $TargetElement
        Index = 0
        OnComplete = $OnComplete
    }

    $timer.Add_Tick({
        param($sender, $e)
        $h = $sender.GetHashCode()
        $data = $global:AppState.Timers["Timer_$h"]
        if ($data.Index -lt $data.Text.Length) {
            $data.Target.Text += $data.Text[$data.Index]
            $data.Index++
            Play-TypewriterTick
        } else {
            $sender.Stop()
            $global:AppState.Timers.Remove("Timer_$h") | Out-Null
            if ($data.OnComplete) { & $data.OnComplete }
        }
    })
    $timer.Start()
}

function Start-MatrixRain {
    $canvas = $global:AppState.Controls.BootMatrixRain
    if (-not $canvas) { return }

    $rainTimer = New-Object System.Windows.Threading.DispatcherTimer
    $rainTimer.Interval = [TimeSpan]::FromMilliseconds(45)

    $global:MatrixDrops = New-Object System.Collections.Generic.List[PSCustomObject]

    $rand = New-Object System.Random
    $windowWidth = if ($global:AppState.Window -and $global:AppState.Window.Width -gt 0) { $global:AppState.Window.Width } else { 800 }
    $windowHeight = if ($global:AppState.Window -and $global:AppState.Window.Height -gt 0) { $global:AppState.Window.Height } else { 840 }

    for ($i = 0; $i -lt 90; $i++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
        $tb.FontSize = $rand.Next(10, 18)
        $tb.Foreground = Get-SolidBrush "#00FF41"
        $tb.Opacity = $rand.NextDouble() * 0.7 + 0.3

        $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $glow.Color = [System.Windows.Media.Color]::FromRgb(0, 255, 65)
        $glow.BlurRadius = 8
        $glow.ShadowDepth = 0
        $glow.Opacity = 0.8
        $tb.Effect = $glow

        $canvas.Children.Add($tb) | Out-Null

        $x = $rand.Next(10, $windowWidth - 20)
        $y = $rand.Next(-$windowHeight, 0)

        [System.Windows.Controls.Canvas]::SetLeft($tb, $x)
        [System.Windows.Controls.Canvas]::SetTop($tb, $y)

        $drop = [PSCustomObject]@{
            Element = $tb
            X = $x
            Y = $y
            Speed = $rand.Next(8, 22)
        }
        $global:MatrixDrops.Add($drop)
    }

    $hash = $rainTimer.GetHashCode()
    $global:AppState.Timers["Timer_$hash"] = @{
        Canvas = $canvas
    }

    $rainTimer.Add_Tick({
        param($sender, $e)
        $h = $sender.GetHashCode()
        $data = $global:AppState.Timers["Timer_$h"]

        # stop the rain once boot screen is gone
        if ($global:AppState.Controls.BootOverlay -and
            $global:AppState.Controls.BootOverlay.Visibility -eq [System.Windows.Visibility]::Collapsed) {
            $sender.Stop()
            $global:AppState.Timers.Remove("Timer_$h") | Out-Null
            $data.Canvas.Children.Clear()
            return
        }

        $liveHeight = if ($data.Canvas.ActualHeight -gt 0) { $data.Canvas.ActualHeight } else { 840 }
        $liveWidth  = if ($data.Canvas.ActualWidth  -gt 0) { $data.Canvas.ActualWidth  } else { 800 }

        $randGen = New-Object System.Random
        foreach ($drop in $global:MatrixDrops) {
            $drop.Y += $drop.Speed
            if ($drop.Y -gt $liveHeight) {
                $drop.Y = $randGen.Next(-100, -20)
                $drop.X = $randGen.Next(10, [Math]::Max(30, [int]$liveWidth - 20))
                $drop.Speed = $randGen.Next(8, 22)
                [System.Windows.Controls.Canvas]::SetLeft($drop.Element, $drop.X)
            }
            [System.Windows.Controls.Canvas]::SetTop($drop.Element, $drop.Y)

            $chars = @("0", "1", "0", "1", "x", "f", "9", "3", "a", "c", "0", "1")
            $drop.Element.Text = $chars[$randGen.Next(0, $chars.Count)]
        }
    })

    $rainTimer.Start()
}

function Start-MainMatrixRain {
    $canvas = $global:AppState.Controls.MainMatrixRain
    if (-not $canvas) { return }

    $rainTimer = New-Object System.Windows.Threading.DispatcherTimer
    $rainTimer.Interval = [TimeSpan]::FromMilliseconds(45)

    $global:MainMatrixDrops = New-Object System.Collections.Generic.List[PSCustomObject]

    $rand = New-Object System.Random
    $windowWidth = if ($global:AppState.Window -and $global:AppState.Window.Width -gt 0) { $global:AppState.Window.Width } else { 800 }
    $windowHeight = if ($global:AppState.Window -and $global:AppState.Window.Height -gt 0) { $global:AppState.Window.Height } else { 840 }

    $columnCount = 200
    $colWidth = $windowWidth / $columnCount

    for ($i = 0; $i -lt $columnCount; $i++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
        $tb.FontWeight = [System.Windows.FontWeights]::Bold
        $tb.FontSize = $rand.Next(14, 26)
        $tb.Foreground = Get-SolidBrush "#00FF41"
        $tb.Opacity = $rand.NextDouble() * 0.6 + 0.3

        # Glow only every 5th column - 100 live DropShadowEffects redrawn on every
        # tick would be a real GPU cost since this rain runs for the app's whole lifetime
        if ($i % 5 -eq 0) {
            $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
            $glow.Color = [System.Windows.Media.Color]::FromRgb(0, 255, 65)
            $glow.BlurRadius = 6
            $glow.ShadowDepth = 0
            $glow.Opacity = 0.7
            $tb.Effect = $glow
        }

        $canvas.Children.Add($tb) | Out-Null

        $x = $i * $colWidth + $rand.Next(-3, 3)
        $y = $rand.Next(-$windowHeight, 0)

        [System.Windows.Controls.Canvas]::SetLeft($tb, $x)
        [System.Windows.Controls.Canvas]::SetTop($tb, $y)

        $drop = [PSCustomObject]@{
            Element = $tb
            X = $x
            Y = $y
            Speed = $rand.Next(6, 16)
        }
        $global:MainMatrixDrops.Add($drop)
    }

    $hash = $rainTimer.GetHashCode()
    $global:AppState.Timers["Timer_$hash"] = @{
        Canvas = $canvas
    }

    $rainTimer.Add_Tick({
        param($sender, $e)
        $h = $sender.GetHashCode()

        # bail out if the window was closed
        if ($global:AppState.Window -and $global:AppState.Window.IsVisible -eq $false) {
            $sender.Stop()
            $global:AppState.Timers.Remove("Timer_$h") | Out-Null
            return
        }

        # Track live window size so the rain reflows as the (now resizable) window changes
        $liveHeight = if ($global:AppState.Window -and $global:AppState.Window.ActualHeight -gt 0) { $global:AppState.Window.ActualHeight } else { 840 }
        $liveWidth  = if ($global:AppState.Window -and $global:AppState.Window.ActualWidth  -gt 0) { $global:AppState.Window.ActualWidth  } else { 800 }

        $randGen = New-Object System.Random
        foreach ($drop in $global:MainMatrixDrops) {
            $drop.Y += $drop.Speed
            if ($drop.Y -gt $liveHeight) {
                $drop.Y = $randGen.Next(-100, -20)
                $drop.Speed = $randGen.Next(6, 16)
            }
            if ($drop.X -gt $liveWidth) {
                [System.Windows.Controls.Canvas]::SetLeft($drop.Element, $randGen.Next(0, [Math]::Max(1, [int]$liveWidth)))
            }
            [System.Windows.Controls.Canvas]::SetTop($drop.Element, $drop.Y)

            $chars = @("0", "1", "A", "C", "F", "9", "3", "0", "1", "B", "E", "D")
            $drop.Element.Text = $chars[$randGen.Next(0, $chars.Count)]
        }
    })

    $rainTimer.Start()
}

function Start-ParticleRain {
    $canvas = $global:AppState.Controls.ParticleRain
    if (-not $canvas) { return }

    $rainTimer = New-Object System.Windows.Threading.DispatcherTimer
    $rainTimer.Interval = [TimeSpan]::FromMilliseconds(60)

    $global:ParticleDrops = New-Object System.Collections.Generic.List[PSCustomObject]

    $rand = New-Object System.Random
    $windowWidth = if ($global:AppState.Window -and $global:AppState.Window.Width -gt 0) { $global:AppState.Window.Width } else { 800 }
    $windowHeight = if ($global:AppState.Window -and $global:AppState.Window.Height -gt 0) { $global:AppState.Window.Height } else { 840 }

    for ($i = 0; $i -lt 70; $i++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
        $tb.FontSize = $rand.Next(6, 9)
        $tb.Foreground = Get-SolidBrush "#00FF41"
        $tb.Opacity = $rand.NextDouble() * 0.25 + 0.1

        $canvas.Children.Add($tb) | Out-Null

        $x = $rand.Next(0, [Math]::Max(1, [int]$windowWidth))
        $y = $rand.Next(-$windowHeight, 0)

        [System.Windows.Controls.Canvas]::SetLeft($tb, $x)
        [System.Windows.Controls.Canvas]::SetTop($tb, $y)

        $drop = [PSCustomObject]@{
            Element = $tb
            X = $x
            Y = $y
            Speed = $rand.NextDouble() * 2 + 1.5
        }
        $global:ParticleDrops.Add($drop)
    }

    $hash = $rainTimer.GetHashCode()
    $global:AppState.Timers["Timer_$hash"] = @{
        Canvas = $canvas
    }

    $rainTimer.Add_Tick({
        param($sender, $e)
        $h = $sender.GetHashCode()

        if ($global:AppState.Window -and $global:AppState.Window.IsVisible -eq $false) {
            $sender.Stop()
            $global:AppState.Timers.Remove("Timer_$h") | Out-Null
            return
        }

        $liveHeight = if ($global:AppState.Window -and $global:AppState.Window.ActualHeight -gt 0) { $global:AppState.Window.ActualHeight } else { 840 }
        $liveWidth  = if ($global:AppState.Window -and $global:AppState.Window.ActualWidth  -gt 0) { $global:AppState.Window.ActualWidth  } else { 800 }

        $randGen = New-Object System.Random
        foreach ($drop in $global:ParticleDrops) {
            $drop.Y += $drop.Speed
            if ($drop.Y -gt $liveHeight) {
                $drop.Y = $randGen.Next(-40, -10)
                $drop.X = $randGen.Next(0, [Math]::Max(1, [int]$liveWidth))
                [System.Windows.Controls.Canvas]::SetLeft($drop.Element, $drop.X)
            }
            [System.Windows.Controls.Canvas]::SetTop($drop.Element, $drop.Y)

            $chars = @("0", "1", ".", ":")
            $drop.Element.Text = $chars[$randGen.Next(0, $chars.Count)]
        }
    })

    $rainTimer.Start()
}

$global:AmbientTargetVolume = 0.55
$global:AmbientFadeSeconds = 1.5
$global:AmbientFadingOut = $false

function Start-AmbientFadeIn {
    param($AudioCtrl)
    try {
        $AudioCtrl.Volume = 0.0
        $global:AmbientFadingOut = $false
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
        $anim.From = 0.0
        $anim.To = $global:AmbientTargetVolume
        $anim.Duration = [TimeSpan]::FromSeconds($global:AmbientFadeSeconds)
        $AudioCtrl.BeginAnimation([System.Windows.Controls.MediaElement]::VolumeProperty, $anim)
    } catch {}
}

function Start-AmbientFadeOut {
    param($AudioCtrl, [double]$Seconds = 1.5)
    try {
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
        $anim.To = 0.0
        $anim.Duration = [TimeSpan]::FromSeconds([Math]::Max(0.2, $Seconds))
        $AudioCtrl.BeginAnimation([System.Windows.Controls.MediaElement]::VolumeProperty, $anim)
    } catch {}
}

function Get-AmbientAudioDirectory {
    $dir = Join-Path $PSScriptRoot "Songs"
    if (-not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {}
    }
    return $dir
}

function Get-AudioTracks {
    $audioDir = Get-AmbientAudioDirectory
    return @(Get-ChildItem -Path $audioDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in ".mp3", ".wav" } |
        Sort-Object Name)
}

function Refresh-AudioTrackList {
    $ctrl = $global:AppState.Controls.MusicTrackList
    if (-not $ctrl) { return }
    try {
        $ctrl.Items.Clear()
        $tracks = Get-AudioTracks
        foreach ($track in $tracks) {
            $ctrl.Items.Add($track.Name) | Out-Null
        }
        if ($tracks.Count -gt 0) {
            if ($ctrl.SelectedIndex -lt 0 -or $ctrl.SelectedIndex -ge $tracks.Count) { $ctrl.SelectedIndex = 0 }
            Add-Log "[*] Found $($tracks.Count) song(s) in Songs\ folder." "#00FF41"
        } else {
            Add-Log "[*] No songs found in Songs\ folder. Add .mp3 or .wav files there to enable music." "#FF9900"
        }
    } catch {}
}

function Play-SelectedAudioTrack {
    param([int]$Index)
    try {
        if (-not $global:AmbientPlaylist -or $global:AmbientPlaylist.Count -eq 0) { return }
        if ($Index -lt 0 -or $Index -ge $global:AmbientPlaylist.Count) { return }
        $audioCtrl = $global:AppState.Controls.BackgroundAudio
        if (-not $audioCtrl) { return }
        $global:AmbientTrackIndex = $Index
        $audioCtrl.Source = [Uri]::new($global:AmbientPlaylist[$Index])
        $audioCtrl.Play()
        Start-AmbientFadeIn -AudioCtrl $audioCtrl
        Add-Log "[*] Playing: $([IO.Path]::GetFileName($global:AmbientPlaylist[$Index]))" "#00FF41"
    } catch {}
}

function Start-SystemAudio {
    try {
        $audioCtrl = $global:AppState.Controls.BackgroundAudio
        if (-not $audioCtrl) { return }

        $tracks = [System.Collections.Generic.List[System.IO.FileInfo]](Get-AudioTracks)

        if ($tracks.Count -eq 0) {
            Add-Log "[*] No ambient audio found in Songs\ folder. Add .mp3/.wav files there to enable background music." "#FF9900"
            return
        }

        $playlist = @($tracks | Select-Object -ExpandProperty FullName)

        $global:AmbientPlaylist = $playlist
        $global:AmbientTrackIndex = 0

        $audioCtrl.Add_MediaEnded({
            $ctrl = $global:AppState.Controls.BackgroundAudio
            if (-not $ctrl -or -not $global:AmbientPlaylist -or $global:AmbientPlaylist.Count -eq 0) { return }
            $global:AmbientTrackIndex = ($global:AmbientTrackIndex + 1) % $global:AmbientPlaylist.Count
            $ctrl.Source = [Uri]::new($global:AmbientPlaylist[$global:AmbientTrackIndex])
            $ctrl.Play()
            Start-AmbientFadeIn -AudioCtrl $ctrl
            Add-Log "[*] Now playing: $([IO.Path]::GetFileName($global:AmbientPlaylist[$global:AmbientTrackIndex]))" "#00FF41"
        })
        $audioCtrl.Source = [Uri]::new($global:AmbientPlaylist[$global:AmbientTrackIndex])
        $audioCtrl.Play()
        Start-AmbientFadeIn -AudioCtrl $audioCtrl
        $global:AmbientMusicPlaying = $true
        Add-Log "[*] Ambient playlist loaded ($($playlist.Count) track(s)). Now playing: $([IO.Path]::GetFileName($global:AmbientPlaylist[$global:AmbientTrackIndex]))" "#00FF41"

        # Watches playback position so the current track fades out just before it ends
        $fadeTimer = New-Object System.Windows.Threading.DispatcherTimer
        $fadeTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $fadeTimer.Add_Tick({
            $ctrl = $global:AppState.Controls.BackgroundAudio
            if (-not $ctrl -or -not $global:AmbientMusicPlaying) { return }
            if (-not $ctrl.NaturalDuration.HasTimeSpan) { return }
            $remaining = $ctrl.NaturalDuration.TimeSpan - $ctrl.Position
            if (-not $global:AmbientFadingOut -and $remaining.TotalSeconds -gt 0 -and $remaining.TotalSeconds -le $global:AmbientFadeSeconds) {
                $global:AmbientFadingOut = $true
                Start-AmbientFadeOut -AudioCtrl $ctrl -Seconds $remaining.TotalSeconds
            }
        })
        $fadeTimer.Start()
        $global:AmbientFadeTimer = $fadeTimer
    } catch {}
}

function Toggle-AmbientAudio {
    try {
        $audioCtrl = $global:AppState.Controls.BackgroundAudio
        $btn = $global:AppState.Controls.PauseMusicBtn
        if (-not $audioCtrl -or -not $audioCtrl.Source) {
            Add-Log "[!] No ambient audio loaded." "#FF9900"
            return
        }
        if ($global:AmbientMusicPlaying) {
            $audioCtrl.Pause()
            $global:AmbientMusicPlaying = $false
            if ($btn) { $btn.Content = "[ > ]" }
        } else {
            $audioCtrl.Play()
            $global:AmbientMusicPlaying = $true
            Start-AmbientFadeIn -AudioCtrl $audioCtrl
            if ($btn) { $btn.Content = "[ || ]" }
        }
    } catch {}
}

function Invoke-ClickFlash {
    try {
        $flash = $global:AppState.Controls.ClickFlash
        if (-not $flash) { return }
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $anim.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero))))
        $anim.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.35, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(40)))))
        $anim.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(220)))))
        $flash.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
    } catch {}
}

function Play-ClickSound {
    # Silent by design (no beep) - visual click-flash instead, see Invoke-ClickFlash.
}

function Play-TypewriterTick {
    try { [Console]::Beep(700, 12) } catch {}
}

# ------------------------------------------------------------------------------
#  4. Security Auditor
# ------------------------------------------------------------------------------
function Verify-LuaFile {
    param([string]$FilePath)
    $name = [IO.Path]::GetFileName($FilePath)
    if (-not (Test-Path $FilePath)) { return @{ Valid=$false; Error="File not found: $name"; Warn=$false } }
    if ([IO.Path]::GetExtension($FilePath).ToLower() -ne ".lua") {
        return @{ Valid=$false; Error="Not a .lua file: $name"; Warn=$true }
    }
    $info = Get-Item $FilePath
    if ($info.Length -eq 0)   { return @{ Valid=$false; Error="File is empty: $name"; Warn=$true } }
    if ($info.Length -gt 1MB) { return @{ Valid=$false; Error="File too large (>1MB): $name"; Warn=$true } }
    try {
        $bytes = [IO.File]::ReadAllBytes($FilePath)
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) {
            return @{ Valid=$false; Error="BLOCKED: Executable disguised as Lua: $name"; Warn=$false }
        }
    } catch { return @{ Valid=$false; Error="Read error: $name"; Warn=$false } }
    return @{ Valid=$true }
}

function Resolve-DatabaseSource {
    param(
        [string]$BackupUrl,
        [string]$LocalRepoPath
    )
    $localDbPath = Join-Path $PSScriptRoot "database"
    if (Test-Path $localDbPath -PathType Container) {
        return [PSCustomObject]@{
            Mode = "local"
            Path = $localDbPath
            BackupUrl = $BackupUrl
            LocalRepoPath = $LocalRepoPath
            Reason = "Bundled local database is available"
        }
    }
    return [PSCustomObject]@{
        Mode = "remote"
        Path = $null
        BackupUrl = $BackupUrl
        LocalRepoPath = $LocalRepoPath
        Reason = "No bundled local database found"
    }
}

# ------------------------------------------------------------------------------
#  OTA (Over-The-Air) Dynamic Update System
# ------------------------------------------------------------------------------
function Check-OtaUpdate {
    [CmdletBinding()]
    param(
        [switch]$Silent
    )
    $otaCandidates = @(
        "https://raw.githubusercontent.com/Baxitts-wq/Mr.-Benkhriza-dllTool/main/version.json",
        "https://raw.githubusercontent.com/Baxitts-wq/Mr.-Benkhriza-Lua-dllTool/main/version.json"
    )
    if ($global:AppState -and $global:AppState.LicenseServerUrl) {
        $otaCandidates = @("$($global:AppState.LicenseServerUrl.TrimEnd('/'))/api/version.json") + $otaCandidates
    }

    $manifest = $null
    foreach ($cand in $otaCandidates) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($cand)
            $req.Timeout = 3000
            $req.UserAgent = "MrBenkhriza-OTA/$($global:AppState.Version)"
            $resp = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $json = $reader.ReadToEnd()
            $reader.Close()
            $resp.Close()

            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $manifest = $json | ConvertFrom-Json
                if ($manifest -and $manifest.version) { break }
            }
        } catch {}
    }

    if (-not $manifest -or -not $manifest.version) {
        if (-not $Silent) {
            Add-Log "[OTA] Aucun serveur de mise a jour joignable pour le moment." "#888888"
        }
        return $false
    }

    try {
        $remoteVer  = [version]$manifest.version
        $currentVer = [version]$global:AppState.Version

        if ($remoteVer -gt $currentVer) {
            Add-Log "=================================================" "#00FFFF"
            Add-Log "[OTA] NOUVELLE MISE A JOUR DETECTEE: v$remoteVer (Version actuelle: v$currentVer)" "#00FFFF"
            if ($manifest.changelog) {
                Add-Log "[OTA] Notes de mise a jour: $($manifest.changelog)" "#00FF41"
            }
            Add-Log "[OTA] Telechargement et installation automatique des correctifs..." "#FF9900"

            $allOk = $true
            if ($manifest.files) {
                foreach ($item in $manifest.files) {
                    if ($item.name -and $item.url) {
                        $target = Join-Path $PSScriptRoot $item.name
                        $tmp = "$target.ota.tmp"
                        try {
                            $wc = New-Object System.Net.WebClient
                            $wc.Headers.Add("User-Agent", "MrBenkhriza-OTA")
                            $wc.DownloadFile($item.url, $tmp)
                            if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 50) {
                                Move-Item -Path $tmp -Destination $target -Force
                                Add-Log "[OTA] [OK] Patch applique: $($item.name)" "#00FF00"
                            } else {
                                $allOk = $false
                            }
                        } catch {
                            Add-Log "[OTA] [!] Erreur pour $($item.name): $($_.Exception.Message)" "#FF3333"
                            $allOk = $false
                        }
                    }
                }
            }

            if ($allOk) {
                Add-Log "[OTA] [SUCCES] Mise a jour v$remoteVer installee avec succes !" "#00FF41"
                Add-Log "[OTA] Redemarrez l'application pour activer toutes les modifications." "#00FFFF"
            }
            Add-Log "=================================================" "#00FFFF"
            return $true
        } else {
            if (-not $Silent) {
                Add-Log "[OTA] Votre application est a jour (v$currentVer)." "#00FF41"
            }
            return $false
        }
    } catch {
        return $false
    }
}

function Set-SteamLaunchOptions {
    param(
        [Parameter(Mandatory=$true)][string]$AppId,
        [switch]$Enable
    )
    if ([string]::IsNullOrWhiteSpace($AppId)) {
        Add-Log "[!] Missing AppID for Steam launch option change." "#FF9900"
        return $false
    }
    $regPath = "HKCU:\Software\Valve\Steam\Apps\$AppId"
    $success = $false
    try {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        if ($Enable) {
            Set-ItemProperty -Path $regPath -Name "LaunchOptions" -Value "-onlinefix" -Type String -ErrorAction Stop
            Add-Log "[*] Steam Registry: LaunchOptions activees pour AppID $AppId (-onlinefix)" "#00FF00"
        } else {
            Remove-ItemProperty -Path $regPath -Name "LaunchOptions" -ErrorAction SilentlyContinue
            Add-Log "[*] Steam Registry: LaunchOptions retirees pour AppID $AppId" "#00FF00"
        }
        $success = $true
    } catch {
        Add-Log "[!] Could not update Steam registry launch options: $($_.Exception.Message)" "#FF3333"
    }

    # Mise a jour dans les profils Steam (userdata/*/config/localconfig.vdf)
    if ($global:AppState -and $global:AppState.SteamRoot) {
        $userDir = Join-Path $global:AppState.SteamRoot "userdata"
        if (Test-Path $userDir) {
            try {
                $subDirs = Get-ChildItem -Path $userDir -Directory -ErrorAction SilentlyContinue
                foreach ($ud in $subDirs) {
                    $vdf = Join-Path $ud.FullName "config\localconfig.vdf"
                    if (Test-Path $vdf) {
                        $txt = [System.IO.File]::ReadAllText($vdf, [System.Text.Encoding]::UTF8)
                        if ($Enable) {
                            if ($txt -match '(?s)("' + $AppId + '"\s*\{[^}]*?"LaunchOptions"\s*")[^"]*(")') {
                                $txt = $txt -replace '(?s)("' + $AppId + '"\s*\{[^}]*?"LaunchOptions"\s*")[^"]*(")', '$1-onlinefix$2'
                                [System.IO.File]::WriteAllText($vdf, $txt, [System.Text.Encoding]::UTF8)
                                Add-Log "[*] Steam VDF: localconfig.vdf mis a jour pour $($ud.Name)" "#00FF00"
                            }
                        } else {
                            if ($txt -match '(?s)("' + $AppId + '"\s*\{[^}]*?"LaunchOptions"\s*")[^"]*(")') {
                                $txt = $txt -replace '(?s)("' + $AppId + '"\s*\{[^}]*?"LaunchOptions"\s*")[^"]*(")', '$1$2'
                                [System.IO.File]::WriteAllText($vdf, $txt, [System.Text.Encoding]::UTF8)
                            }
                        }
                    }
                }
            } catch {}
        }
    }

    return $success
}

# ------------------------------------------------------------------------------
#  5. Metadata Parser
# ------------------------------------------------------------------------------
function Get-GameMetadata {
    param([string]$FilePath)
    $fileName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    $appId    = $fileName
    $title    = $fileName
    if (Test-Path $FilePath) {
        try {
            $linesArr = @(Get-Content $FilePath -TotalCount 2)
            if ($linesArr.Count -ge 1 -and $linesArr[0] -match '^--\s*(.*)$') {
                $raw   = $Matches[1].Trim()
                $clean = $raw -replace "[\u200B\u200C\u200D\uFEFF]", ''
                $clean = $clean -replace '[^\x20-\x7E]', ''
                if ($clean.Trim()) { $title = $clean.Trim() }
            }
            if ($linesArr.Count -ge 2 -and $linesArr[1] -match 'AppID\s*(\d+)') {
                $appId = $Matches[1]
            }
        } catch {}
    }
    return [PSCustomObject]@{
        Title    = $title
        AppId    = $appId
        FilePath = $FilePath
        Display  = "$title  [$appId]"
    }
}

$global:GamesCache = @()

function Load-GameDatabase {
    if (-not (Test-Path $global:AppState.DbPath)) {
        New-Item -ItemType Directory -Path $global:AppState.DbPath -Force | Out-Null
    }
    $global:GamesCache = @(Get-ChildItem -Path $global:AppState.DbPath -Filter "*.lua" |
        ForEach-Object { Get-GameMetadata $_.FullName } |
        Sort-Object Title)
}

function Refresh-GameList {
    $filter = if ($global:AppState.Controls.SearchBox) { $global:AppState.Controls.SearchBox.Text } else { "" }
    $global:AppState.Controls.GameList.Items.Clear()
    foreach ($g in $global:GamesCache) {
        if ([string]::IsNullOrEmpty($filter) -or
            $g.Title -like "*$filter*" -or
            $g.AppId -like "*$filter*") {
            $global:AppState.Controls.GameList.Items.Add($g.Display) | Out-Null
        }
    }
    if ($global:AppState.Controls.DbCountLabel) {
        $global:AppState.Controls.DbCountLabel.Text = "> DB: $($global:GamesCache.Count) GAMES LOADED"
    }
}

# ------------------------------------------------------------------------------
#  6. Injector & Import Engines
# ------------------------------------------------------------------------------
function Install-LuaFiles {
    param([string[]]$Files)
    $ok=0; $skip=0; $fail=0
    Add-Log "[+] Injection pipeline: $($Files.Count) file(s)..." "#00FF00"
    foreach ($f in $Files) {
        $name = [IO.Path]::GetFileName($f)
        $v = Verify-LuaFile $f
        if (-not $v.Valid) {
            if ($v.Warn) { Add-Log "[!] [SKIP] $($v.Error)" "#FF9900"; $skip++ }
            else         { Add-Log "[!] [BLOCK] $($v.Error)" "#FF3333"; $fail++ }
            continue
        }
        try {
            Copy-Item $f (Join-Path $global:AppState.SteamLuaPath $name) -Force
            Add-Log "[*] [OK] Injected: $name" "#00FF00"
            $ok++
        } catch {
            Add-Log "[!] [ERR] Failed: $name - $($_.Exception.Message)" "#FF3333"
            $fail++
        }
    }
    if ($ok -gt 0) {
        Add-Log "[*] Done: $ok injected, $skip skipped, $fail blocked." "#00FF00"
        Add-Log "[*] Files are now live in Steam loader." "#00FF00"
    } else {
        Add-Log "[!] Done: 0 injected, $skip skipped, $fail blocked." "#FF9900"
    }
}

function Import-FilesToDatabase {
    param([string[]]$Files)
    $imported = @()
    foreach ($f in $Files) {
        $name = [IO.Path]::GetFileName($f)
        $v = Verify-LuaFile $f
        if (-not $v.Valid) {
            if ($v.Warn) { Add-Log "[!] [SKIP] $($v.Error)" "#FF9900" }
            else         { Add-Log "[!] [BLOCK] $($v.Error)" "#FF3333" }
            continue
        }
        try {
            $dest = Join-Path $global:AppState.DbPath $name
            Copy-Item $f $dest -Force
            Add-Log "[+] Imported to catalog: $name" "#00FF00"
            $imported += $dest

            # Upload to central community database in background
            try {
                $serverUrl = if ($global:AppState -and $global:AppState.LicenseServerUrl) { $global:AppState.LicenseServerUrl } else { "http://192.168.129.130:8080" }
                $uploadUrl = "$($serverUrl.TrimEnd('/'))/api/lua/upload"
                $luaContent = Get-Content -LiteralPath $f -Raw -Encoding utf8
                $body = @{
                    filename = $name
                    content  = $luaContent
                } | ConvertTo-Json
                $null = Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $body -ContentType "application/json" -TimeoutSec 5 -ErrorAction SilentlyContinue
                Add-Log "[CLOUD] Shared $name with central community database." "#00FF00"
            } catch {}
        } catch { Add-Log "[!] [ERR] Import failed: $name" "#FF3333" }
    }
    if ($imported.Count -gt 0) {
        Load-GameDatabase
        Refresh-GameList
        $last = Get-GameMetadata $imported[-1]
        $global:AppState.Controls.GameList.SelectedItem = $last.Display
        Add-Log "[*] Catalog updated - select a game and click INJECT." "#00FF00"
    }
}

# ------------------------------------------------------------------------------
#  6b. Archive Package Import Engine (ZIP / RAR / 7z / Bypass / Fix Online)
# ------------------------------------------------------------------------------
function Expand-ArchiveAny {
    # Returns $true on success, $false on failure
    param([string]$ArchivePath, [string]$DestDir)

    $ext = [System.IO.Path]::GetExtension($ArchivePath).ToLower()

    # --- ZIP : utilise l'assembly .NET natif (pas besoin d'outils externes) ---
    if ($ext -eq ".zip") {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestDir)
            return $true
        } catch {
            Add-Log "[ZIP] [ERR] Echec extraction ZIP natif: $($_.Exception.Message)" "#FF3333"
            return $false
        }
    }

    # --- RAR / 7z / autre : essai 7-Zip puis WinRAR ---
    $sz7Path = $null
    try { $sz7Cmd = Get-Command "7z" -ErrorAction SilentlyContinue; if ($sz7Cmd) { $sz7Path = $sz7Cmd.Source } } catch {}
    $sevenZipCandidates = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        $sz7Path
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($sevenZipCandidates.Count -gt 0) {
        $sz = $sevenZipCandidates[0]
        Add-Log "[ARCHIVE] Extraction via 7-Zip: $sz" "#888888"
        try {
            $result = & $sz x "$ArchivePath" "-o$DestDir" -y 2>&1
            if ($LASTEXITCODE -eq 0) { return $true }
            Add-Log "[ARCHIVE] [ERR] 7-Zip code $LASTEXITCODE" "#FF3333"
            return $false
        } catch {
            Add-Log "[ARCHIVE] [ERR] 7-Zip exception: $($_.Exception.Message)" "#FF3333"
            return $false
        }
    }

    # --- WinRAR fallback ---
    $winrarCandidates = @(
        "$env:ProgramFiles\WinRAR\WinRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe",
        "$env:ProgramFiles\WinRAR\Rar.exe",
        "${env:ProgramFiles(x86)}\WinRAR\Rar.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($winrarCandidates.Count -gt 0) {
        $wr = $winrarCandidates[0]
        Add-Log "[ARCHIVE] Extraction via WinRAR: $wr" "#888888"
        try {
            $result = & $wr x -y "$ArchivePath" "$DestDir\" 2>&1
            if ($LASTEXITCODE -eq 0) { return $true }
            Add-Log "[ARCHIVE] [ERR] WinRAR code $LASTEXITCODE" "#FF3333"
            return $false
        } catch {
            Add-Log "[ARCHIVE] [ERR] WinRAR exception: $($_.Exception.Message)" "#FF3333"
            return $false
        }
    }

    Add-Log "[ARCHIVE] [ERR] Aucun extracteur trouve (7-Zip ou WinRAR). Installez 7-Zip pour supporter les .rar/.7z." "#FF3333"
    Add-Log "[ARCHIVE] Telechargez 7-Zip sur: https://7-zip.org" "#FF9900"
    return $false
}

function Import-ArchivePackage {
    param([string]$ZipPath)

    $zipName = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $isOnlineFix = ($zipName -match '(?i)(onlinefix|online.fix|bypass|fix)') -or
                   ([System.IO.Path]::GetFileName($ZipPath) -match '(?i)(onlinefix|online.fix|bypass|fix)')

    Add-Log "=================================================" "#00FFFF"
    Add-Log "[ZIP] Analyse du paquet: $([System.IO.Path]::GetFileName($ZipPath))" "#00FFFF"
    if ($isOnlineFix) {
        Add-Log "[ZIP] Type detecte: BYPASS / ONLINEFIX ZIP - Installation automatique activee." "#FF9900"
    } else {
        Add-Log "[ZIP] Type detecte: Archive generique - Extraction des composants." "#888888"
    }

    # Chargement de l'assembly ZIP
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    } catch {}

    $tempExtract = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "MrBenkhrizaArc_$([System.IO.Path]::GetRandomFileName())")
    $ok = Expand-ArchiveAny -ArchivePath $ZipPath -DestDir $tempExtract
    if (-not $ok) {
        Add-Log "[ARCHIVE] [ERR] Impossible d'extraire l'archive." "#FF3333"
        return
    }
    Add-Log "[ARCHIVE] Archive extraite vers dossier temporaire." "#00FF00"

    $luaFiles     = @(Get-ChildItem -Path $tempExtract -Recurse -Filter "*.lua" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $dllFiles     = @(Get-ChildItem -Path $tempExtract -Recurse -Filter "*.dll" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $tomlFiles    = @(Get-ChildItem -Path $tempExtract -Recurse -Filter "*.toml" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $exeFiles     = @(Get-ChildItem -Path $tempExtract -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

    Add-Log "[ARCHIVE] Contenu trouve: $($luaFiles.Count) LUA, $($dllFiles.Count) DLL, $($tomlFiles.Count) TOML, $($exeFiles.Count) EXE (ignores)" "#00FF41"

    # --- Traitement des fichiers LUA ---
    $importedLuas = @()
    foreach ($lua in $luaFiles) {
        $luaName = [System.IO.Path]::GetFileName($lua)
        $v = Verify-LuaFile $lua
        if (-not $v.Valid) {
            if ($v.Warn) { Add-Log "[ZIP] [SKIP] $($v.Error)" "#FF9900" }
            else         { Add-Log "[ZIP] [BLOCK] Fichier dangereux ignore: $luaName" "#FF3333" }
            continue
        }
        try {
            $dest = Join-Path $global:AppState.DbPath $luaName
            Copy-Item $lua $dest -Force
            Add-Log "[ARCHIVE] [LUA] Importe dans le catalogue: $luaName" "#00FF00"
            $importedLuas += $dest

            # Upload vers le serveur central
            try {
                $serverUrl = if ($global:AppState -and $global:AppState.LicenseServerUrl) { $global:AppState.LicenseServerUrl } else { "http://192.168.129.130:8080" }
                $uploadUrl = "$($serverUrl.TrimEnd('/'))/api/lua/upload"
                $luaContent = Get-Content -LiteralPath $lua -Raw -Encoding utf8
                $body = @{ filename = $luaName; content = $luaContent } | ConvertTo-Json
                $null = Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $body -ContentType "application/json" -TimeoutSec 5 -ErrorAction SilentlyContinue
                Add-Log "[CLOUD] Partage de $luaName avec la base centrale." "#00FF00"
            } catch {}
        } catch {
            Add-Log "[ARCHIVE] [ERR] Echec import LUA: $luaName - $($_.Exception.Message)" "#FF3333"
        }
    }

    # --- Traitement des fichiers DLL / TOML (SteamFiles) ---
    $steamFilesDir = Join-Path $PSScriptRoot "SteamFiles"
    if (-not (Test-Path $steamFilesDir)) { try { New-Item -ItemType Directory -Path $steamFilesDir -Force | Out-Null } catch {} }

    $sfCopied = 0
    foreach ($sf in ($dllFiles + $tomlFiles)) {
        $sfName = [System.IO.Path]::GetFileName($sf)
        # Securite: ne jamais copier un DLL suspect de plus de 20MB
        $sfInfo = Get-Item $sf -ErrorAction SilentlyContinue
        if ($sfInfo -and $sfInfo.Length -gt 20MB) {
            Add-Log "[ARCHIVE] [SKIP] DLL trop volumineux (>20MB): $sfName" "#FF9900"
            continue
        }
        try {
            $dest = Join-Path $steamFilesDir $sfName
            Copy-Item $sf $dest -Force
            Add-Log "[ARCHIVE] [SF] Copie dans SteamFiles: $sfName" "#00FF00"
            $sfCopied++
        } catch {
            Add-Log "[ARCHIVE] [ERR] Echec copie SteamFiles: $sfName" "#FF3333"
        }
    }

    # Deployer les SteamFiles dans Steam si necessaire
    if ($sfCopied -gt 0 -and $global:AppState.SteamRoot) {
        try { Initialize-SteamEnvironment } catch {}
        Add-Log "[ARCHIVE] SteamFiles deployes dans $($global:AppState.SteamRoot)." "#00FF41"
    }

    # --- Mise a jour de la base locale ---
    if ($importedLuas.Count -gt 0) {
        Load-GameDatabase
        Refresh-GameList
        $last = Get-GameMetadata $importedLuas[-1]
        $global:AppState.Controls.GameList.SelectedItem = $last.Display
    }

    # --- Auto-injection si bypass/onlinefix detecte ---
    if ($isOnlineFix -and $importedLuas.Count -gt 0) {
        Add-Log "[ARCHIVE] [AUTO] Mode bypass detecte - injection automatique des LUA..." "#FF9900"
        Install-LuaFiles $importedLuas

        # Injecter aussi 480.lua pour le support OnlineFix
        $lua480 = Join-Path $global:AppState.DbPath "480.lua"
        if (-not (Test-Path $lua480)) {
            "-- Spacewar (OnlineFix Multiplayer Overlay)`n-- AppID 480`naddappid(480)" | Out-File $lua480 -Encoding utf8
        }
        Install-LuaFiles @($lua480)
        Add-Log "[ARCHIVE] [AUTO] Injection Spacewar 480 efectuee pour le support multijoueur." "#00FF41"
    } elseif ($importedLuas.Count -gt 0) {
        Add-Log "[ARCHIVE] Catalogue mis a jour. Selectionnez un jeu et cliquez [ INJECT LUA ] pour injecter." "#00FF41"
    }

    # Nettoyage du dossier temporaire
    try { Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue } catch {}

    Add-Log "[ARCHIVE] Traitement termine: $($importedLuas.Count) LUA(s), $sfCopied composant(s) Steam." "#00FFFF"
    Add-Log "=================================================" "#00FFFF"
}

# ------------------------------------------------------------------------------
#  7. Community Central Sync & GitHub Backup Engine
# ------------------------------------------------------------------------------
function Update-SelectedLua {
    $sel = $global:AppState.Controls.GameList.SelectedItem
    if (-not $sel) { Add-Log "[!] Selectionnez d'abord un jeu dans la liste locale a mettre a jour." "#FF9900"; return }
    $g = $global:GamesCache | Where-Object { $_.Display -eq $sel } | Select-Object -First 1
    if (-not $g) { Add-Log "[!] Metadonnees introuvables pour le jeu selectionne." "#FF3333"; return }

    Add-Log "=================================================" "#00FFFF"
    Add-Log "[*] Recherche de mise a jour pour: $($g.Title) (AppID $($g.AppId))..." "#00FF41"

    $serverUrl = if ($global:AppState -and $global:AppState.LicenseServerUrl) { $global:AppState.LicenseServerUrl } else { "http://192.168.129.130:8080" }
    $updated = $false

    # 1. Verification sur le serveur central Cloud / mini-supabase
    try {
        $syncUrl = "$($serverUrl.TrimEnd('/'))/api/lua/sync"
        $remoteLuas = Invoke-RestMethod -Uri $syncUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
        $match = $remoteLuas | Where-Object { $_.app_id -eq "$($g.AppId)" -or $_.filename -like "$($g.AppId)*.lua" } | Select-Object -First 1
        if ($match -and $match.content) {
            $destFile = if ($g.FilePath) { $g.FilePath } else { Join-Path $global:AppState.DbPath "$($g.AppId).lua" }
            $existingContent = if (Test-Path $destFile) { [System.IO.File]::ReadAllText($destFile, [System.Text.Encoding]::UTF8) } else { "" }
            if ($existingContent.Trim() -ne $match.content.Trim()) {
                [System.IO.File]::WriteAllText($destFile, $match.content, [System.Text.Encoding]::UTF8)
                Add-Log "[CLOUD] [SUCCES] LUA mis a jour depuis la base centrale Cloud !" "#00FF00"
                $updated = $true
            } else {
                Add-Log "[CLOUD] [OK] Le script local est deja parfaitement synchronise avec la base centrale." "#00FF00"
                $updated = $true
            }
        }
    } catch {
        Add-Log "[!] Serveur central injoignable ($($_.Exception.Message)). Recherche sur le depot GitHub backup..." "#FF9900"
    }

    # 2. Si pas trouve ou indisponible, verification sur GitHub backup
    if (-not $updated) {
        try {
            $url = $global:AppState.BackupUrl
            $directUrl = "$($url.TrimEnd('/'))/$($g.AppId).lua"
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "MrBenkhriza-LuaUpdater/2.3")
            $remoteContent = $wc.DownloadString($directUrl)
            if (-not [string]::IsNullOrWhiteSpace($remoteContent) -and $remoteContent -match "addappid") {
                $destFile = if ($g.FilePath) { $g.FilePath } else { Join-Path $global:AppState.DbPath "$($g.AppId).lua" }
                [System.IO.File]::WriteAllText($destFile, $remoteContent, [System.Text.Encoding]::UTF8)
                Add-Log "[GITHUB] [SUCCES] LUA mis a jour depuis le depot GitHub !" "#00FF00"
                $updated = $true
            }
        } catch {}
    }

    if ($updated) {
        Load-GameDatabase
        Refresh-GameList
        $newMeta = $global:GamesCache | Where-Object { $_.AppId -eq "$($g.AppId)" } | Select-Object -First 1
        if ($newMeta) { $global:AppState.Controls.GameList.SelectedItem = $newMeta.Display }
    } else {
        Add-Log "[!] Aucune version plus recente trouvee en ligne pour AppID $($g.AppId)." "#FF9900"
    }
    Add-Log "=================================================" "#00FFFF"
}

function Sync-Database {
    Add-Log "[+] Synchronizing catalog with central database..." "#00FF00"
    try {
        $serverUrl = if ($global:AppState -and $global:AppState.LicenseServerUrl) { $global:AppState.LicenseServerUrl } else { "http://192.168.129.130:8080" }
        $syncUrl = "$($serverUrl.TrimEnd('/'))/api/lua/sync"
        $remoteLuas = Invoke-RestMethod -Uri $syncUrl -Method Get -TimeoutSec 10 -ErrorAction Stop
        $newCount = 0
        $updatedCount = 0
        foreach ($item in $remoteLuas) {
            if ($item.filename -and $item.content) {
                $destFile = Join-Path $global:AppState.DbPath $item.filename
                $shouldWrite = $false
                if (-not (Test-Path $destFile)) {
                    $shouldWrite = $true
                    $newCount++
                } else {
                    $existingContent = [System.IO.File]::ReadAllText($destFile, [System.Text.Encoding]::UTF8)
                    if ($existingContent.Trim() -ne $item.content.Trim()) {
                        $shouldWrite = $true
                        $updatedCount++
                    }
                }
                if ($shouldWrite) {
                    [System.IO.File]::WriteAllText($destFile, $item.content, [System.Text.Encoding]::UTF8)
                }
            }
        }
        if ($newCount -gt 0 -or $updatedCount -gt 0) {
            Add-Log "[CLOUD] $newCount nouveau(x) script(s) ajoute(s), $updatedCount script(s) mis a jour !" "#00FF00"
            Load-GameDatabase; Refresh-GameList
            return
        } else {
            Add-Log "[CLOUD] Tous les scripts LUA locaux sont parfaitement a jour ($($remoteLuas.Count) scripts synchronises)." "#00FF00"
        }
    } catch {
        Add-Log "[!] Central server sync unavailable: $($_.Exception.Message). Trying fallbacks..." "#FF9900"
    }

    $source = Resolve-DatabaseSource -BackupUrl $global:AppState.BackupUrl -LocalRepoPath $global:AppState.LocalRepoPath
    if ($source.Mode -eq "local") {
        Add-Log "[*] Bundled local database detected at $($source.Path)." "#00FF00"
    }

    $gitDir = if ($global:AppState.LocalRepoPath) { $global:AppState.LocalRepoPath } else { Resolve-Path "$PSScriptRoot\.." }
    $isGit = (Test-Path "$gitDir\.git") -and (Get-Command git -ErrorAction SilentlyContinue)
    if ($isGit) {
        Add-Log "[+] Git repository detected. Syncing database via git pull..." "#00FF00"
        try {
            $prevFiles = Get-ChildItem -Path $global:AppState.DbPath -Filter "*.lua" | Select-Object -ExpandProperty Name
            $null = & git -C $gitDir pull origin main 2>&1
            $srcDb = Join-Path $gitDir "gui\database"
            if (Test-Path $srcDb) {
                Copy-Item -Path "$srcDb\*.lua" -Destination $global:AppState.DbPath -Force -ErrorAction SilentlyContinue
            }
            $newFiles = Get-ChildItem -Path $global:AppState.DbPath -Filter "*.lua" | Select-Object -ExpandProperty Name
            $added = 0
            foreach ($file in $newFiles) { if ($file -notin $prevFiles) { $added++ } }
            Add-Log "[*] Git sync complete - $added new file(s) updated/added." "#00FF00"
            Load-GameDatabase; Refresh-GameList
            return
        } catch {
            Add-Log "[!] Git sync failed: $($_.Exception.Message). Falling back..." "#FF9900"
        }
    }

    Load-GameDatabase; Refresh-GameList
}

# ------------------------------------------------------------------------------
#  8. Steam Store Online Search Engine
# ------------------------------------------------------------------------------
$global:SteamSearchResults = @()

function Search-SteamStore {
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Add-Log "[!] Enter a game name to search." "#FF9900"; return
    }
    Add-Log "[*] Searching Steam Store for: $Query" "#FF9900"
    $global:AppState.Controls.SteamResultList.Items.Clear()
    $global:SteamSearchResults = @()
    $global:AppState.Controls.SteamGameInfo.Text = "> Searching Steam Store..."
    try {
        $encoded = [System.Uri]::EscapeDataString($Query)
        $url = "https://store.steampowered.com/api/storesearch/?term=$encoded&l=english&cc=US"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 10
        if ($response.items -and $response.items.Count -gt 0) {
            foreach ($item in $response.items) {
                if ($item.type -eq "app") {
                    $inDb    = $global:GamesCache | Where-Object { $_.AppId -eq "$($item.id)" }
                    $tag     = if ($inDb) { " [IN CATALOG]" } else { "" }
                    $display = "$($item.name)$tag  [AppID: $($item.id)]"
                    $global:AppState.Controls.SteamResultList.Items.Add($display) | Out-Null
                    $global:SteamSearchResults += [PSCustomObject]@{
                        Name    = $item.name
                        AppId   = $item.id
                        Display = $display
                        InDb    = ($null -ne $inDb)
                    }
                }
            }
            $cnt = $global:SteamSearchResults.Count
            Add-Log "[*] Found $cnt result(s) for '$Query'" "#FF9900"
            $global:AppState.Controls.SteamGameInfo.Text = "> $cnt results found - select a game below"
        } else {
            Add-Log "[!] No results found for '$Query'" "#FF9900"
            $global:AppState.Controls.SteamGameInfo.Text = "> No results. Try a different search term."
        }
    } catch {
        Add-Log "[!] [ERR] Steam search failed: $($_.Exception.Message)" "#FF3333"
        $global:AppState.Controls.SteamGameInfo.Text = "> Search error - check internet connection."
    }
}

function Get-SelectedSteamGame {
    $sel = $global:AppState.Controls.SteamResultList.SelectedItem
    if (-not $sel) { return $null }
    return $global:SteamSearchResults | Where-Object { $_.Display -eq $sel } | Select-Object -First 1
}

function Test-WebView2Installed {
    $keys = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    return $false
}

function Show-WebView2FallbackDialog {
    param([PSCustomObject]$Game)
    $url = "https://openlua.cloud/"
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mr. Benkhriza - Fetch LUA" Height="300" Width="520"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#0A0A0F" Topmost="True">
    <Grid Margin="28">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="FETCH LUA Ã¢â‚¬â€ BROWSER REQUIRED" FontFamily="Consolas" FontSize="14"
                   Foreground="#FF9900" FontWeight="Bold" Margin="0,0,0,12"/>
        <TextBlock Grid.Row="1" FontFamily="Consolas" FontSize="11" Foreground="#CCCCCC"
                   TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="The automatic LUA fetch needs Microsoft Edge WebView2 Runtime which is not installed on this machine."/>
        <TextBlock Grid.Row="2" FontFamily="Consolas" FontSize="11" Foreground="#AAAAAA"
                   TextWrapping="Wrap" Margin="0,0,0,18"
                   Text="You can either open the page manually in your browser, or download WebView2 to enable automatic fetching."/>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="OpenBrowserBtn" Content="[ OPEN IN BROWSER ]" FontFamily="Consolas" FontSize="11"
                    Background="#00FF41" Foreground="#000000" FontWeight="Bold"
                    BorderThickness="0" Padding="14,7" Margin="0,0,10,0" Cursor="Hand"/>
            <Button x:Name="DownloadWV2Btn" Content="[ GET WEBVIEW2 ]" FontFamily="Consolas" FontSize="11"
                    Background="#1A1A2E" Foreground="#FF9900" FontWeight="Bold"
                    BorderBrush="#FF9900" BorderThickness="1" Padding="14,7" Margin="0,0,10,0" Cursor="Hand"/>
            <Button x:Name="CloseBtn" Content="[ CLOSE ]" FontFamily="Consolas" FontSize="11"
                    Background="#1A1A2E" Foreground="#FF003C" FontWeight="Bold"
                    BorderBrush="#FF003C" BorderThickness="1" Padding="14,7" Cursor="Hand"/>
        </StackPanel>
    </Grid>
</Window>
"@
    try {
        $reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
        $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
        $dlg.FindName("OpenBrowserBtn").Add_Click({
            try { Start-Process "https://openlua.cloud/?q=$([Uri]::EscapeDataString($Game.Name))" } catch {}
            $dlg.Close()
        })
        $dlg.FindName("DownloadWV2Btn").Add_Click({
            try { Start-Process "https://developer.microsoft.com/microsoft-edge/webview2/" } catch {}
            $dlg.Close()
        })
        $dlg.FindName("CloseBtn").Add_Click({ $dlg.Close() })
        $dlg.ShowDialog() | Out-Null
    } catch {
        # Fallback: just open in browser
        try { Start-Process "https://openlua.cloud/?q=$([Uri]::EscapeDataString($Game.Name))" } catch {}
    }
}

function Launch-WebView2Crawler {
    param([PSCustomObject]$Game)

    # Check WebView2 is installed first
    if (-not (Test-WebView2Installed)) {
        Add-Log "[!] WebView2 Runtime is not installed. Showing fallback options..." "#FF9900"
        $global:AppState.Controls.SteamGameInfo.Text = "> WebView2 not found. Opening browser fallback..."
        Show-WebView2FallbackDialog -Game $Game
        return
    }

    $fetchScript = Join-Path $PSScriptRoot "lib\fetch_lua.ps1"
    $libDir      = Join-Path $PSScriptRoot "lib"
    if (-not (Test-Path $fetchScript)) {
        Add-Log "[!] Fetch script not found. Re-run Setup.bat to repair." "#FF3333"
        Add-Log "[!] Manual fallback: visit https://openlua.cloud and search for: $($Game.Name)" "#FF9900"
        $global:AppState.Controls.SteamGameInfo.Text = "> Re-run Setup.bat, or get LUA manually from openlua.cloud"
        return
    }
    $tempFile = [System.IO.Path]::GetTempFileName()
    Remove-Item $tempFile -Force
    Add-Log "[+] Launching WebView2 browser for $($Game.Name)..." "#FF9900"
    Add-Log "[+] The browser will auto-search and download the LUA file." "#888888"

    $psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$fetchScript`" -AppId `"$($Game.AppId)`" -GameName `"$($Game.Name)`" -TempFile `"$tempFile`" -LibDir `"$libDir`""

    try {
        $proc = Start-Process powershell -ArgumentList $psArgs -PassThru -NoNewWindow:$false
        $global:AppState.Window.IsEnabled = $false

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(500)
        $timer.Add_Tick(({
            $exited = $false
            try { $proc.Refresh(); $exited = $proc.HasExited } catch { $exited = $true }
            if ($exited) {
                try { $timer.Stop() } catch {}
                $global:AppState.Window.IsEnabled = $true
                try {
                    $errFile = $tempFile + ".error"
                    if (Test-Path $errFile) {
                        $errMsg = Get-Content $errFile -Raw
                        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
                        Add-Log "[!] Browser error: $errMsg" "#FF3333"
                        Add-Log "[!] Manual fallback: https://openlua.cloud - search '$($Game.Name)' then drag and drop the .lua here." "#FF9900"
                        $global:AppState.Controls.SteamGameInfo.Text = "> Browser failed. Get LUA from openlua.cloud and drag and drop here."
                        return
                    }
                    if (Test-Path $tempFile) {
                        $luaContent = Get-Content $tempFile -Raw
                        if ($luaContent -match 'addappid') {
                            $dest = Join-Path $global:AppState.DbPath "$($Game.AppId).lua"
                            $header = if ($luaContent -notmatch "AppID $($Game.AppId)") { "-- $($Game.Name)`r`n-- AppID $($Game.AppId) | Auto-fetched from openlua.cloud`r`n" } else { "" }
                            [System.IO.File]::WriteAllText($dest, $header + $luaContent, [System.Text.Encoding]::UTF8)
                            Add-Log "[*] [OK] Captured LUA for $($Game.Name)!" "#00FF00"
                            Load-GameDatabase; Refresh-GameList
                            $meta = Get-GameMetadata $dest
                            $global:AppState.Controls.GameList.SelectedItem = $meta.Display
                            Add-Log "[*] Added to catalog. Go to LOCAL DATABASE tab and click INJECT." "#00FF00"
                            $global:AppState.Controls.SteamGameInfo.Text = "> LUA downloaded! Go to LOCAL DATABASE tab and inject."
                        } else {
                            Add-Log "[!] Downloaded content is not valid LUA." "#FF3333"
                        }
                        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    } else {
                        Add-Log "[!] Browser closed without capturing LUA (cancelled or timed out)." "#FF9900"
                        Add-Log "[!] Manual: visit https://openlua.cloud, search '$($Game.Name)', download .lua, drag and drop here." "#FF9900"
                        $global:AppState.Controls.SteamGameInfo.Text = "> Timed out. Get from openlua.cloud and drag and drop here."
                    }
                } catch {
                    Add-Log "[!] Post-processing error: $($_.Exception.Message)" "#FF3333"
                }
            }
        }).GetNewClosure())
        $timer.Start()
    } catch {
        Add-Log "[!] Failed to launch browser: $($_.Exception.Message)" "#FF3333"
        $global:AppState.Window.IsEnabled = $true
    }
}


function Fetch-LuaFromBackup {
    param([PSCustomObject]$Game)
    if (-not $Game) {
        Add-Log "[!] Select a game from the Steam search results first." "#FF9900"; return
    }
    $existing = $global:GamesCache | Where-Object { $_.AppId -eq "$($Game.AppId)" }
    if ($existing) {
        Add-Log "[*] Jeu deja repertorie localement: $($Game.Name) [$($Game.AppId)]. Recherche d'une version plus recente..." "#00FFFF"
    }

    Add-Log "[+] Searching backup repo for AppID $($Game.AppId)..." "#FF9900"

    $gitDir = if ($global:AppState.LocalRepoPath) { $global:AppState.LocalRepoPath } else { Resolve-Path "$PSScriptRoot\.." }
    $isGit = (Test-Path "$gitDir\.git") -and (Get-Command git -ErrorAction SilentlyContinue)
    if ($isGit) {
        Add-Log "[+] Git repository detected. Searching remote branch..." "#FF9900"
        try {
            $null = & git -C $gitDir fetch origin main 2>&1
            $appIdStr = "$($Game.AppId)"
            $remoteFiles = & git -C $gitDir ls-tree -r --name-only origin/main gui/database 2>&1
            $foundPath = $remoteFiles | Where-Object { $_ -match "gui/database/${appIdStr}.*\.lua" } | Select-Object -First 1
            if ($foundPath) {
                $fileName = [IO.Path]::GetFileName($foundPath)
                $dest = Join-Path $global:AppState.DbPath $fileName
                $fileContent = & git -C $gitDir show "origin/main:$foundPath" 2>&1
                $fileContent | Out-File $dest -Encoding utf8
                $gitDest = Join-Path $gitDir "gui\database\$fileName"
                if ($dest -ne $gitDest -and (Test-Path (Join-Path $gitDir "gui\database"))) {
                    $fileContent | Out-File $gitDest -Encoding utf8
                }
                Add-Log "[*] [OK] Downloaded: $fileName" "#00FF00"
                Load-GameDatabase; Refresh-GameList
                $meta = Get-GameMetadata $dest
                $global:AppState.Controls.GameList.SelectedItem = $meta.Display
                Add-Log "[*] Added to catalog. Switch to LOCAL DATABASE tab and click INJECT." "#00FF00"
                $global:AppState.Controls.SteamGameInfo.Text = "> Downloaded! Now go to LOCAL DATABASE tab and inject."
                return
            } else {
                Launch-WebView2Crawler -Game $Game; return
            }
        } catch {
            Add-Log "[!] Git fetch/search failed: $($_.Exception.Message). Falling back to Web API..." "#FF9900"
        }
    }

    $url        = $global:AppState.BackupUrl
    $rawPattern = 'raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)'
    if ($url -match $rawPattern) {
        $owner  = $Matches[1]; $repo   = $Matches[2]
        $branch = $Matches[3]; $path   = $Matches[4].TrimEnd('/')
        $apiUrl = "https://api.github.com/repos/$owner/$repo/contents/$path"
    } else {
        Add-Log "[!] Cannot resolve backup repo API URL." "#FF3333"; return
    }

    try {
        $headers  = @{ "User-Agent" = "Benkhriza-Bypass-Loader/2.1" }
        if ($global:AppState.GithubToken) { $headers.Add("Authorization", "token $($global:AppState.GithubToken)") }
        $listing  = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -TimeoutSec 10
        $appIdStr = "$($Game.AppId)"
        $found    = $listing | Where-Object { $_.name -like "${appIdStr}*" -and $_.name -like "*.lua" } | Select-Object -First 1
        if ($found) {
            $dest = Join-Path $global:AppState.DbPath $found.name
            Invoke-RestMethod -Uri $found.download_url -OutFile $dest -Headers $headers -TimeoutSec 10
            Add-Log "[*] [OK] Downloaded: $($found.name)" "#00FF00"
            Load-GameDatabase; Refresh-GameList
            $meta = Get-GameMetadata $dest
            $global:AppState.Controls.GameList.SelectedItem = $meta.Display
            Add-Log "[*] Added to catalog. Switch to LOCAL DATABASE tab and click INJECT." "#00FF00"
            $global:AppState.Controls.SteamGameInfo.Text = "> Downloaded! Now go to LOCAL DATABASE tab and inject."
        } else {
            Launch-WebView2Crawler -Game $Game
        }
    } catch {
        Add-Log "[!] Backup repo search failed ($($_.Exception.Message)). Attempting browser crawler..." "#FF9900"
        Launch-WebView2Crawler -Game $Game
    }
}

function Open-SteamDb {
    param([PSCustomObject]$Game)
    if (-not $Game) {
        Add-Log "[!] Select a game from the search results first." "#FF9900"; return
    }
    $url = "https://www.steamdb.info/app/$($Game.AppId)/info/"
    Add-Log "[*] Opening SteamDB page for $($Game.Name)..." "#4A9EFF"
    try { Start-Process $url } catch { Add-Log "[!] Could not open browser." "#FF3333" }
}

# ------------------------------------------------------------------------------
#  9. Load XAML Window
# ------------------------------------------------------------------------------
[xml]$xamlData = $null
if (Test-Path $global:AppState.XamlPath) {
    try { $xamlData = Get-Content $global:AppState.XamlPath -Raw } catch {}
}

# Inline minimal fallback if external XAML not found
if (-not $xamlData) {
    $xamlData = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="[ BENKHRIZA v2.1 ]" Width="640" Height="840"
        WindowStartupLocation="CenterScreen" Background="#000000" AllowDrop="True" Opacity="1.0">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="BENKHRIZA v2.1" FontFamily="Consolas" FontSize="18" Foreground="#FF0000" HorizontalAlignment="Center" Margin="0,0,0,8"/>
        <Grid Grid.Row="1" Margin="0,0,0,6">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBox x:Name="SearchBox" Background="#050505" Foreground="#00FF00" BorderBrush="#00FF00" Height="26" FontFamily="Consolas"/>
            <TextBlock x:Name="DbCountLabel" Grid.Column="1" Foreground="#00FF00" FontFamily="Consolas" Margin="6,0,0,0" VerticalAlignment="Center"/>
        </Grid>
        <ListBox x:Name="GameList" Grid.Row="2" Background="#000000" Foreground="#00FF00" FontFamily="Consolas"/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,6,0,6">
            <TextBox x:Name="SteamSearchBox" Width="300" Background="#050505" Foreground="#00FF00" BorderBrush="#FF9900" Height="26" FontFamily="Consolas"/>
            <Button x:Name="SteamSearchBtn" Content="SEARCH" Background="#050505" Foreground="#FF9900" Margin="4,0" Height="26" FontFamily="Consolas"/>
            <Button x:Name="FetchLuaBtn" Content="FETCH LUA" Background="#050505" Foreground="#00FF00" Margin="4,0" Height="26" FontFamily="Consolas"/>
            <Button x:Name="OpenSteamDbBtn" Content="STEAMDB" Background="#050505" Foreground="#4A9EFF" Height="26" FontFamily="Consolas"/>
        </StackPanel>
        <ListBox x:Name="SteamResultList" Grid.Row="3" Background="#000000" Foreground="#FF9900" FontFamily="Consolas" Height="80" Margin="0,36,0,0"/>
        <TextBlock x:Name="SteamGameInfo" Grid.Row="3" Foreground="#FF9900" FontFamily="Consolas" Margin="0,120,0,0"/>
        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Button x:Name="InjectBtn" Grid.Column="0" Content="INJECT" Background="#050505" Foreground="#00FF00" Height="30" FontFamily="Consolas"/>
            <Button x:Name="InjectOnlineFixBtn" Grid.Column="1" Content="ONLINEFIX" Background="#050505" Foreground="#FF9900" Height="30" FontFamily="Consolas" Margin="4,0"/>
            <Button x:Name="SyncBtn" Grid.Column="2" Content="SYNC" Background="#050505" Foreground="#FF9900" Height="30" FontFamily="Consolas" Margin="4,0"/>
            <Button x:Name="BrowseBtn" Grid.Column="3" Content="IMPORT" Background="#050505" Foreground="#00FF00" Height="30" FontFamily="Consolas"/>
            <Button x:Name="FixSpacewarBtn" Visibility="Collapsed"/>
            <Button x:Name="UpdateLuaBtn" Visibility="Collapsed"/>
        </Grid>
        <ScrollViewer x:Name="LogScroll" Grid.Row="4" Margin="0,36,0,0" Height="100" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="LogPanel"/>
        </ScrollViewer>
        <Canvas x:Name="MainMatrixRain" Grid.RowSpan="5" Background="Transparent" IsHitTestVisible="False" Opacity="0.08"/>
        <Grid x:Name="BootOverlay" Background="#000000" Panel.ZIndex="100" Grid.RowSpan="5" Visibility="Collapsed"/>
        <TextBlock x:Name="BootSplashText" Grid.Row="0" Visibility="Collapsed"/>
        <Image x:Name="BootLogoImage" Grid.Row="0" Width="0" Visibility="Collapsed"/>
        <Canvas x:Name="BootMatrixRain" Grid.RowSpan="5" Background="Transparent" IsHitTestVisible="False" Visibility="Collapsed"/>
        <Image x:Name="LogoImage" Grid.Row="0" Width="0" Visibility="Collapsed"/>
        <TextBlock x:Name="BootPathLog" Grid.Row="0" Visibility="Collapsed"/>
        <TextBlock x:Name="BootPathLog2" Grid.Row="0" Visibility="Collapsed"/>
        <CheckBox x:Name="OnlineFixChk" Grid.Row="4" Margin="0,36,0,0" Visibility="Collapsed"/>
        <Button x:Name="ClearBtn" Grid.Row="4" Margin="0,0,0,0" Content="CLEAR" Foreground="#FF0000" Background="#050505" Height="26" Width="80" HorizontalAlignment="Right" FontFamily="Consolas"/>
        <MediaElement x:Name="BackgroundAudio" Visibility="Collapsed" LoadedBehavior="Manual" UnloadedBehavior="Stop"/>
    </Grid>
</Window>
"@
}

[xml]$xmlObj  = $xamlData
$xmlReader    = New-Object System.Xml.XmlNodeReader $xmlObj
$global:AppState.Window = [Windows.Markup.XamlReader]::Load($xmlReader)

# Map all controls
$controlNames = @(
    "SearchBox", "GameList", "InjectBtn", "InjectOnlineFixBtn", "OnlineFixChk", "SyncBtn", "FixSpacewarBtn", "UpdateLuaBtn",
    "SteamSearchBox", "SteamSearchBtn", "SteamResultList",
    "SteamGameInfo", "FetchLuaBtn", "OpenSteamDbBtn",
    "LogPanel", "LogScroll", "ClearBtn", "BrowseBtn",
    "LogoImage", "BootPathLog", "BootPathLog2", "DbCountLabel", "BackgroundAudio",
    "BootOverlay", "BootSplashText", "BootLogoImage", "BootMatrixRain", "MainMatrixRain",
    "ParticleRain", "ClickFlash", "PauseMusicBtn", "MusicTrackList",
    "AdminAuthGrid", "AdminPasswordBox", "AdminUnlockBtn", "AdminAuthError",
    "AdminPanelGrid", "AdminLicenseList", "AdminSelectedKeyText", "AdminSelectedHwidText",
    "AdminSelectedIpText", "AdminSelectedStatusText", "AdminSelectedDateText",
    "AdminGenKeyBtn", "AdminResetHwidBtn", "AdminActivateKeyBtn", "AdminRevokeKeyBtn"
)
foreach ($n in $controlNames) {
    $ctrl = $global:AppState.Window.FindName($n)
    if ($ctrl) { $global:AppState.Controls[$n] = $ctrl }
}

if ($global:AppState.Controls.BootPathLog) {
    $global:AppState.Controls.BootPathLog.Text = "> TARGET: $($global:AppState.SteamLuaPath)"
}
if ($global:AppState.Controls.BootPathLog2) {
    $global:AppState.Controls.BootPathLog2.Text = "[BOOT] Steam Lua dir: $($global:AppState.SteamLuaPath)"
}

if ($global:AppState.LogoBase64) {
    try {
        $bytes  = [Convert]::FromBase64String($global:AppState.LogoBase64)
        $ms     = New-Object System.IO.MemoryStream(,$bytes)
        $bmp    = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.StreamSource = $ms
        $bmp.CacheOption  = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()

        # Mr_Benkhriza_Logo.png has asymmetric transparent padding around the badge
        # (left/right margins 34px/13px, top/bottom 18px/35px on the 497x503 source),
        # so a plain UniformToFill stretch renders the badge visibly off-center.
        # Crop to a square centered on the badge itself before displaying it.
        $displaySource = $bmp
        try {
            $cropRect = New-Object System.Windows.Int32Rect(23, 7, 472, 472)
            $cropped = New-Object System.Windows.Media.Imaging.CroppedBitmap($bmp, $cropRect)
            $displaySource = $cropped
        } catch {}

        if ($global:AppState.Controls.LogoImage)     { $global:AppState.Controls.LogoImage.Source = $displaySource }
        if ($global:AppState.Controls.BootLogoImage) { $global:AppState.Controls.BootLogoImage.Source = $displaySource }
    } catch {}
}

# ------------------------------------------------------------------------------
#  10. Event Wiring
# ------------------------------------------------------------------------------
$buttonList = @("InjectBtn", "InjectOnlineFixBtn", "SyncBtn", "SteamSearchBtn", "FetchLuaBtn", "OpenSteamDbBtn", "BrowseBtn", "ClearBtn", "FixSpacewarBtn", "UpdateLuaBtn")
foreach ($btnName in $buttonList) {
    $btnCtrl = $global:AppState.Controls[$btnName]
    if ($btnCtrl) { $btnCtrl.Add_Click({ Invoke-ClickFlash }) }
}

if ($global:AppState.Controls.PauseMusicBtn) {
    $global:AppState.Controls.PauseMusicBtn.Add_Click({ Toggle-AmbientAudio })
}
if ($global:AppState.Controls.MusicTrackList) {
    $global:AppState.Controls.MusicTrackList.Add_SelectionChanged({
        $selIndex = $global:AppState.Controls.MusicTrackList.SelectedIndex
        if ($selIndex -ge 0) { Play-SelectedAudioTrack -Index $selIndex }
    })
}

if ($global:AppState.Controls.SearchBox) {
    $global:AppState.Controls.SearchBox.Add_TextChanged({ Refresh-GameList })
    $global:AppState.Controls.SearchBox.Add_TextChanged({ Play-TypewriterTick })
}

if ($global:AppState.Controls.InjectBtn) {
    $global:AppState.Controls.InjectBtn.Add_Click({
        $sel = $global:AppState.Controls.GameList.SelectedItem
        if (-not $sel) { Add-Log "[!] Select a game from the list first." "#FF9900"; return }
        $g = $global:GamesCache | Where-Object { $_.Display -eq $sel } | Select-Object -First 1
        if ($g) { Install-LuaFiles @($g.FilePath) }
        else    { Add-Log "[!] Game metadata not found." "#FF3333" }
    })
}

if ($global:AppState.Controls.InjectOnlineFixBtn) {
    $global:AppState.Controls.InjectOnlineFixBtn.Add_Click({
        $sel = $global:AppState.Controls.GameList.SelectedItem
        if (-not $sel) { Add-Log "[!] Veuillez selectionner un jeu dans la liste d'abord." "#FF9900"; return }
        $g = $global:GamesCache | Where-Object { $_.Display -eq $sel } | Select-Object -First 1
        if ($g) {
            Add-Log "=================================================" "#00FFFF"
            Add-Log "[*] [ONLINEFIX v3] Configuration Multijoueur pour $($g.Title) (AppID $($g.AppId))..." "#00FF41"

            # 1. Injecter le script Lua du jeu
            Add-Log "[*] [ONLINEFIX] Etape 1/4: Injection du manifeste Lua du jeu..." "#00FF00"
            Install-LuaFiles @($g.FilePath)

            # 2. Injecter Spacewar (AppID 480) pour le matchmaking OnlineFix
            $lua480 = Join-Path $global:AppState.DbPath "480.lua"
            if (-not (Test-Path $lua480)) {
                "-- Spacewar (OnlineFix Multiplayer Overlay)`n-- AppID 480`naddappid(480)" | Out-File $lua480 -Encoding utf8
            }
            Add-Log "[*] [ONLINEFIX] Etape 2/4: Injection du hook multijoueur Spacewar (480)..." "#00FF00"
            Install-LuaFiles @($lua480)

            # 3. Configurer les options de lancement -onlinefix pour le jeu ET pour Spacewar 480
            Add-Log "[*] [ONLINEFIX] Etape 3/4: Application de l'argument Steam (-onlinefix)..." "#00FF00"
            $null = Set-SteamLaunchOptions -AppId $g.AppId -Enable:$true
            $null = Set-SteamLaunchOptions -AppId "480" -Enable:$true
            if ($global:AppState.Controls.OnlineFixChk) {
                $global:AppState.Controls.OnlineFixChk.IsChecked = $true
            }

            # 4. Detection et lancement
            $steamProcess = Get-Process steam -ErrorAction SilentlyContinue
            if ($steamProcess) {
                Add-Log "[*] [ONLINEFIX] Etape 4/4: Steam en execution detecte." "#00FF00"
                Add-Log "[*] Lancement direct avec -onlinefix via Steam..." "#00FF41"
                try {
                    Start-Process "steam://run/$($g.AppId)//-onlinefix"
                    Add-Log "[+] Commande envoyee a Steam avec succes !" "#00FF00"
                } catch {
                    Add-Log "[!] Impossible d'invoquer l'URL Steam: $($_.Exception.Message)" "#FF3333"
                }
                Add-Log "[i] CONSEIL MULTIJOUEUR: Si le jeu ne detecte pas les serveurs/amis, fermez completement Steam puis relancez-le." "#00FFFF"
            } else {
                Add-Log "[*] [ONLINEFIX] Etape 4/4: Steam est ferme. LaunchOptions pre-configurees." "#00FF00"
                Add-Log "[+] Demarrez Steam pour jouer en ligne !" "#00FF41"
            }

            Add-Log "[i] Note Spacewar: Si necessaire, cliquez sur [ FIX SPACEWAR 480 ] pour activer la licence Spacewar sur votre compte." "#00FFFF"
            Add-Log "=================================================" "#00FFFF"
        } else {
            Add-Log "[!] Metadonnees du jeu introuvables." "#FF3333"
        }
    })
}

if ($global:AppState.Controls.FixSpacewarBtn) {
    $global:AppState.Controls.FixSpacewarBtn.Add_Click({
        Add-Log "=================================================" "#00FFFF"
        Add-Log "[*] [SPACEWAR 480] Configuration du hook multijoueur Spacewar..." "#00FF41"
        $lua480 = Join-Path $global:AppState.DbPath "480.lua"
        if (-not (Test-Path $lua480)) {
            "-- Spacewar (OnlineFix Multiplayer Overlay)`n-- AppID 480`naddappid(480)" | Out-File $lua480 -Encoding utf8
        }
        Install-LuaFiles @($lua480)
        $null = Set-SteamLaunchOptions -AppId "480" -Enable:$true

        Add-Log "[*] Lancement du protocole d'enregistrement Steam pour Spacewar..." "#00FF00"
        try {
            Start-Process "steam://install/480"
            Add-Log "[+] Commande steam://install/480 executee avec succes !" "#00FF00"
        } catch {
            try { Start-Process "steam://run/480" } catch {}
        }
        Add-Log "[*] Spacewar (AppID 480) est pret pour tous vos jeux OnlineFix." "#00FF41"
        Add-Log "=================================================" "#00FFFF"
    })
}

if ($global:AppState.Controls.UpdateLuaBtn) {
    $global:AppState.Controls.UpdateLuaBtn.Add_Click({
        Update-SelectedLua
    })
}

if ($global:AppState.Controls.OnlineFixChk) {
    $global:AppState.Controls.OnlineFixChk.Add_Click({
        $sel = $global:AppState.Controls.GameList.SelectedItem
        if (-not $sel) { return }
        $g = $global:GamesCache | Where-Object { $_.Display -eq $sel } | Select-Object -First 1
        if ($g) {
            $isChecked = ($global:AppState.Controls.OnlineFixChk.IsChecked -eq $true)
            Set-SteamLaunchOptions -AppId $g.AppId -Enable:$isChecked | Out-Null
            if ($isChecked) {
                Add-Log "[*] Drapeau OnlineFix active pour $($g.Title)." "#00FF00"
            } else {
                Add-Log "[*] Drapeau OnlineFix desactive pour $($g.Title)." "#FF9900"
            }
        }
    })
}

if ($global:AppState.Controls.SyncBtn) {
    $global:AppState.Controls.SyncBtn.Add_Click({ Sync-Database })
}

if ($global:AppState.Controls.SteamSearchBtn) {
    $global:AppState.Controls.SteamSearchBtn.Add_Click({
        Search-SteamStore -Query $global:AppState.Controls.SteamSearchBox.Text
    })
}

if ($global:AppState.Controls.SteamSearchBox) {
    $global:AppState.Controls.SteamSearchBox.Add_TextChanged({ Play-TypewriterTick })
    $global:AppState.Controls.SteamSearchBox.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            Search-SteamStore -Query $global:AppState.Controls.SteamSearchBox.Text
        }
    })
}

if ($global:AppState.Controls.SteamResultList) {
    $global:AppState.Controls.SteamResultList.Add_SelectionChanged({
        $g = Get-SelectedSteamGame
        if ($g) {
            $inDb = if ($g.InDb) { " - ALREADY IN CATALOG" } else { " - not in catalog" }
            $global:AppState.Controls.SteamGameInfo.Text = "> $($g.Name) [AppID: $($g.AppId)]$inDb"
        }
    })
}

if ($global:AppState.Controls.FetchLuaBtn) {
    $global:AppState.Controls.FetchLuaBtn.Add_Click({
        Fetch-LuaFromBackup -Game (Get-SelectedSteamGame)
    })
}

if ($global:AppState.Controls.OpenSteamDbBtn) {
    $global:AppState.Controls.OpenSteamDbBtn.Add_Click({
        Open-SteamDb -Game (Get-SelectedSteamGame)
    })
}

if ($global:AppState.Controls.BrowseBtn) {
    $global:AppState.Controls.BrowseBtn.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = "Lua Config files (*.lua)|*.lua"
        $dlg.Multiselect = $true
        $dlg.Title = "Import Lua files to local catalog"
        if ($dlg.ShowDialog()) { Import-FilesToDatabase $dlg.FileNames }
    })
}

if ($global:AppState.Controls.ClearBtn) {
    $global:AppState.Controls.ClearBtn.Add_Click({
        if ($global:AppState.Controls.LogPanel) { $global:AppState.Controls.LogPanel.Children.Clear() }
        Add-Log "[*] Log cleared." "#00FF00"
    })
}

$global:AppState.Window.Add_DragEnter({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $e.Effects = [System.Windows.DragDropEffects]::Copy
        $e.Handled = $true
    }
})
$global:AppState.Window.Add_DragOver({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $e.Effects = [System.Windows.DragDropEffects]::Copy
        $e.Handled = $true
    }
})
$global:AppState.Window.Add_Drop({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        $luaFiles = @(); $zipFiles = @(); $dllFiles = @()
        foreach ($f in $files) {
            $ext = [System.IO.Path]::GetExtension($f).ToLower()
            switch ($ext) {
                ".lua"  { $luaFiles += $f }
                ".zip"  { $zipFiles += $f }
                ".rar"  { $zipFiles += $f }
                ".7z"   { $zipFiles += $f }
                ".dll"  { $dllFiles += $f }
                default {
                    Add-Log "[!] Type non supporte: $([System.IO.Path]::GetFileName($f)) (ZIP/RAR/7z/LUA/DLL attendu)" "#FF9900"
                }
            }
        }
        # Traitement des LUA directement deposes
        if ($luaFiles.Count -gt 0) { Import-FilesToDatabase $luaFiles }
        # Traitement des archives (ZIP / RAR / 7z)
        foreach ($zf in $zipFiles) { Import-ArchivePackage -ZipPath $zf }
        # Traitement des DLL isoles (copie dans SteamFiles + deploiement)
        if ($dllFiles.Count -gt 0) {
            $destDir = Join-Path $PSScriptRoot "SteamFiles"
            if (-not (Test-Path $destDir)) { try { New-Item -ItemType Directory -Path $destDir -Force | Out-Null } catch {} }
            foreach ($pf in $dllFiles) {
                $name = [System.IO.Path]::GetFileName($pf)
                try {
                    Copy-Item $pf (Join-Path $destDir $name) -Force
                    Add-Log "[*] [OK] DLL copie dans SteamFiles: $name" "#00FF00"
                } catch { Add-Log "[!] [ERR] Echec copie DLL: $name - $($_.Exception.Message)" "#FF3333" }
            }
            try { Initialize-SteamEnvironment } catch {}
        }
    }
})

# ------------------------------------------------------------------------------
#  11. Startup
# ------------------------------------------------------------------------------
Load-GameDatabase
Refresh-GameList
Refresh-AudioTrackList

# ------------------------------------------------------------------------------
#  11b. License Gate (runs before the main window opens)
# ------------------------------------------------------------------------------
if (-not $global:TestOnly) {
    $existingRecord = Load-LicenseAuthRecord

    # Check for hardware mismatch (tampering / cloned install)
    if ($existingRecord -and $existingRecord.Tampered) {
        [System.Windows.MessageBox]::Show(
            "ACCESS DENIED`n`nViolation de sécurité matérielle détectée (HWID différent ou copie non autorisée).`n`nCette licence est strictement liée à sa machine d'origine.",
            "Mr. Benkhriza - Protection Sécurité",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Stop
        ) | Out-Null
        [System.Environment]::Exit(0)
    }

    $storedKey = Load-LicenseKey

    # No key cached - show standalone activation dialog
    if ([string]::IsNullOrWhiteSpace($storedKey)) {
        $activationResult = Show-LicenseEntryDialog
        if (-not $activationResult.Activated) {
            [System.Environment]::Exit(0)
        }
        $storedKey = $activationResult.Key
        $existingRecord = Load-LicenseAuthRecord
    }

    # Determine if we already have a valid local lease
    $hasValidLocalLease = ($existingRecord -and -not $existingRecord.Tampered -and $existingRecord.Key -eq $storedKey)

    # Validate key against Server (with seamless offline fallback if locally bound)
    $authResult = Test-SupabaseLicense -LicenseKey $storedKey -AllowOfflineFallback:$hasValidLocalLease

    if ($authResult.Success) {
        if ($authResult.Mode -eq "OfflineVerified") {
            $global:AppState.LicenseMode = "OfflineVerified"
            Save-LicenseAuthRecord -Key $storedKey -OnlineVerified $false | Out-Null
        } else {
            $global:AppState.LicenseMode = "OnlineVerified"
            Save-LicenseAuthRecord -Key $storedKey -OnlineVerified $true | Out-Null
        }
    } else {
        # Server explicitly rejected key (HWIDMismatch on server, SuspendedKey, InvalidKey)
        if ($authResult.Mode -eq "HWIDMismatch" -or $authResult.Mode -eq "SuspendedKey" -or $authResult.Mode -eq "InvalidKey") {
            try { Remove-Item (Get-AuthFilePath) -Force -ErrorAction SilentlyContinue } catch {}
        }
        [System.Windows.MessageBox]::Show(
            "ACCESS DENIED`n`n$($authResult.Message)`n`nContact the author to resolve this.",
            "Mr. Benkhriza - Security",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Stop
        ) | Out-Null
        [System.Environment]::Exit(0)
    }

    $global:AppState.HWID = Get-SystemHWID
}

if ($global:AppState.Window) {
    $global:AppState.Window.Add_Loaded({
        $hwid = Get-SystemHWID
        $global:AppState.HWID = $hwid

        if ($global:AppState.LicenseMode -eq "OfflineVerified") {
            Add-Log "[SECURITY] [OFFLINE] Machine validée en local [HWID: $($hwid.Substring(0,8))...] Mode Hors Ligne actif." "#00FF41"
        } else {
            Add-Log "[SECURITY] [ONLINE] Serveur connecté. Licence vérifiée [HWID: $($hwid.Substring(0,8))...]" "#00FF41"
        }
        Start-SystemAudio
        Start-MatrixRain
        Start-MainMatrixRain
        Start-ParticleRain

        # Watchdog: forces boot overlay closed after 2 seconds
        if ($global:AppState.Controls.BootOverlay) {
            $watchdog = New-Object System.Windows.Threading.DispatcherTimer
            $watchdog.Interval = [TimeSpan]::FromMilliseconds(2000)
            $watchdog.Add_Tick({
                param($sender, $e)
                $sender.Stop()
                if ($global:AppState.Controls.BootOverlay.Visibility -ne [System.Windows.Visibility]::Collapsed) {
                    $global:AppState.Controls.BootOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                    Add-Log "[BOOT] [WARN] Boot screen forced closed via watchdog." "#FF9900"
                    Add-TypewriterLog "[BOOT] Benkhriza BYPASS LOADER v3.0" "#00FF00" 5 {
                        Add-TypewriterLog "[BOOT] SYSTEM INITIALIZING..." "#00FF00" 5 {
                            Add-TypewriterLog "[BOOT] Memory hooks established. System ready." "#00FF00" 5 {
                                Add-Log "[BOOT] Catalog loaded - $($global:GamesCache.Count) game(s) in database." "#00FF00"
                                Add-Log "[BOOT] System ready. Use LOCAL DATABASE to inject, SEARCH STEAM STORE to find new games." "#00FF00"
                            }
                        }
                    }
                }
            })
            $watchdog.Start()
        }

        if ($global:AppState.Controls.BootSplashText -and $global:AppState.Controls.BootOverlay) {
            Add-TypewriterLogToElement -TargetElement $global:AppState.Controls.BootSplashText -Text "LOADING CORE MODULES..." -CharDelayMs 20 -OnComplete {
                $pauseTimer = New-Object System.Windows.Threading.DispatcherTimer
                $pauseTimer.Interval = [TimeSpan]::FromMilliseconds(300)
                $hash = $pauseTimer.GetHashCode()
                $global:AppState.Timers["Timer_$hash"] = @{ Timer = $pauseTimer }
                $pauseTimer.Add_Tick({
                    param($sender, $e)
                    $sender.Stop()
                    $h = $sender.GetHashCode()
                    $global:AppState.Timers.Remove("Timer_$h") | Out-Null
                    Add-TypewriterLogToElement -TargetElement $global:AppState.Controls.BootSplashText -Text "INITIALIZING STEAM HOOKS..." -CharDelayMs 20 -OnComplete {
                        $holdTimer = New-Object System.Windows.Threading.DispatcherTimer
                        $holdTimer.Interval = [TimeSpan]::FromMilliseconds(680)
                        $h2 = $holdTimer.GetHashCode()
                        $global:AppState.Timers["Timer_$h2"] = @{ Timer = $holdTimer }
                        $holdTimer.Add_Tick({
                            param($sender2, $e2)
                            $sender2.Stop()
                            $h3 = $sender2.GetHashCode()
                            $global:AppState.Timers.Remove("Timer_$h3") | Out-Null
                            if ($global:AppState.Controls.BootOverlay.Visibility -ne [System.Windows.Visibility]::Collapsed) {
                                $global:AppState.Controls.BootOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                                Add-TypewriterLog "[BOOT] Benkhriza BYPASS LOADER v3.0" "#00FF00" 5 {
                                    Add-TypewriterLog "[BOOT] SYSTEM INITIALIZING..." "#00FF00" 5 {
                                        Add-TypewriterLog "[BOOT] Memory hooks established. System ready." "#00FF00" 5 {
                                            Add-Log "[BOOT] Catalog loaded - $($global:GamesCache.Count) game(s) in database." "#00FF00"
                                            Add-Log "[BOOT] System ready." "#00FF00"
                                            try { Check-OtaUpdate -Silent } catch {}

                                            # Synchronisation silencieuse en tâche de fond si démarré hors ligne
                                            if ($global:AppState.LicenseMode -eq "OfflineVerified") {
                                                [System.Threading.ThreadPool]::QueueUserWorkItem({
                                                    Start-Sleep -Seconds 6
                                                    try {
                                                        $rec = Load-LicenseAuthRecord
                                                        if ($rec -and $rec.Key) {
                                                            $check = Test-SupabaseLicense -LicenseKey $rec.Key
                                                            if ($check.Success -and $check.Mode -ne "OfflineVerified") {
                                                                Save-LicenseAuthRecord -Key $rec.Key -OnlineVerified $true | Out-Null
                                                            }
                                                        }
                                                    } catch {}
                                                }) | Out-Null
                                            }
                                        }
                                    }
                                }
                            }
                        })
                        $holdTimer.Start()
                    }
                })
                $pauseTimer.Start()
            }
        } else {
            if ($global:AppState.Controls.BootOverlay) {
                $global:AppState.Controls.BootOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            }
            Add-TypewriterLog "[BOOT] Benkhriza BYPASS LOADER v3.0" "#00FF00" 5
        }
    })
}

if (-not $global:TestOnly) {
    try {
        $runGui = {
            $global:AppState.Window.Visibility = [System.Windows.Visibility]::Visible
            $global:AppState.Window.Activate() | Out-Null
            $global:AppState.Window.ShowDialog() | Out-Null
        }
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
            $staThread = New-Object System.Threading.Thread($runGui)
            $staThread.SetApartmentState([System.Threading.ApartmentState]::STA)
            $staThread.Start()
            $staThread.Join()
        } else {
            & $runGui
        }
    } catch {
        $logFile = Join-Path $PSScriptRoot "boot_error.txt"
        "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] SHOWDIALOG EXCEPTION:" | Out-File $logFile -Append -Encoding utf8
        $_.Exception.ToString() | Out-File $logFile -Append -Encoding utf8
        [System.Windows.MessageBox]::Show("Startup Error:`n$($_.Exception.Message)", "Mr. Benkhriza", 0, 16) | Out-Null
    }
}

