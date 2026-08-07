# fetch_lua.ps1 — Runs in a background STA runspace
# Launches a WebView2 browser, navigates to openlua.cloud,
# auto-solves Cloudflare Turnstile (real Chromium = passes),
# intercepts the LUA blob, and saves it to TempFile.
param(
    [string]$AppId,
    [string]$GameName,
    [string]$TempFile,
    [string]$LibDir
)

Set-StrictMode -Off

# ---- Load assemblies ----
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class NativeHelper {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    public static extern bool SetDllDirectory(string lpPathName);
}
"@
# ---- Unblock & Load assemblies ----
Get-ChildItem -Path $LibDir -Filter "*.dll" -Recurse | ForEach-Object {
    Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
    $zoneFile = $_.FullName + ":Zone.Identifier"
    if (Test-Path $zoneFile) { Remove-Item $zoneFile -Force -ErrorAction SilentlyContinue }
}

try {
    Add-Type -Path (Join-Path $LibDir "Microsoft.Web.WebView2.Core.dll")
    Add-Type -Path (Join-Path $LibDir "Microsoft.Web.WebView2.WinForms.dll")
} catch {
    [System.IO.File]::WriteAllText($TempFile + ".error", "WebView2 DLL load failed: $_")
    exit 1
}

# ---- Build Form ----
$form           = New-Object System.Windows.Forms.Form
$form.Text      = "[ BENKHRIZA - Fetching LUA: $GameName ]"
$form.Width     = 900
$form.Height    = 680
$form.StartPosition = 'CenterScreen'
$form.ShowInTaskbar = $true

$lbl            = New-Object System.Windows.Forms.Label
$lbl.Dock       = 'Bottom'
$lbl.Height     = 28
$lbl.BackColor  = [System.Drawing.Color]::Black
$lbl.ForeColor  = [System.Drawing.Color]::Lime
$lbl.Font       = New-Object System.Drawing.Font("Consolas", 9)
$lbl.Text       = "  Initializing browser..."
$form.Controls.Add($lbl)

$wv             = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$creationProps  = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$creationProps.UserDataFolder = Join-Path $env:TEMP "MrBenkhrizaWV2"
$wv.CreationProperties = $creationProps
$wv.Dock        = 'Fill'
$form.Controls.Add($wv)

# ---- Intercept Script (injected before ANY page script runs) ----
$interceptJs = @'
(function () {
    'use strict';

    /* Capture blob downloads (openlua serves LUA as blob URL) */
    var _createObjectURL = URL.createObjectURL;
    URL.createObjectURL = function (blob) {
        try {
            var r = new FileReader();
            r.onloadend = function () {
                var t = r.result;
                if (typeof t === 'string' && t.indexOf('addappid') !== -1) {
                    window.chrome.webview.postMessage(JSON.stringify({ type: 'LUA', content: t }));
                }
            };
            r.readAsText(blob);
        } catch (_) {}
        return _createObjectURL.apply(this, arguments);
    };

    /* Capture fetch() responses from download/fix/bypass endpoints */
    var _fetch = window.fetch;
    window.fetch = function () {
        var args = arguments;
        return _fetch.apply(this, args).then(function (resp) {
            try {
                var u = (typeof args[0] === 'string') ? args[0] : ((args[0] && args[0].url) || '');
                if (/\/(download|fix|bypass)\//.test(u)) {
                    resp.clone().blob().then(function (b) {
                        var r = new FileReader();
                        r.onloadend = function () {
                            var t = r.result;
                            if (typeof t === 'string' && t.indexOf('addappid') !== -1) {
                                window.chrome.webview.postMessage(JSON.stringify({ type: 'LUA', content: t }));
                            }
                        };
                        r.readAsText(b);
                    }).catch(function () {});
                }
            } catch (_) {}
            return resp;
        });
    };
})();
'@

# ---- Trigger Script (runs after page navigation completes) ----
$safeGameName = $GameName -replace "'", "\\'" -replace '"', '\\"'
$triggerJs = @"
(function () {
    var TARGET_APPID = '$AppId';
    var TARGET_NAME  = '$safeGameName';

    function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

    async function run() {
        await sleep(2500);

        /* --- Step 1: Find the search box and type the game name --- */
        var inp = document.querySelector(
            'input[type="search"], input[type="text"], input[placeholder], input:not([type])'
        );
        if (!inp) { inp = Array.from(document.querySelectorAll('input')).find(function(i){ return !i.readOnly && !i.disabled && i.offsetParent; }); }
        if (!inp) return;

        /* Native React/Svelte-friendly value setter */
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
        if (setter && setter.set) setter.set.call(inp, TARGET_NAME);
        else inp.value = TARGET_NAME;

        inp.dispatchEvent(new Event('input',  { bubbles: true }));
        inp.dispatchEvent(new Event('change', { bubbles: true }));
        inp.dispatchEvent(new KeyboardEvent('keydown', { key:'Enter', keyCode:13, bubbles:true }));
        inp.dispatchEvent(new KeyboardEvent('keyup',   { key:'Enter', keyCode:13, bubbles:true }));

        var f = inp.closest('form');
        if (f) f.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));

        await sleep(3000);

        /* --- Step 2: Click the matching game result --- */
        var nameShort = TARGET_NAME.toLowerCase().substring(0, Math.min(8, TARGET_NAME.length));
        var els = Array.from(document.querySelectorAll('a, button, li, [role="option"], [role="listitem"]'));
        var matched = els.find(function(e) {
            var t = (e.textContent || '').trim().toLowerCase();
            var h = e.href || '';
            return h.includes(TARGET_APPID) || t.includes(nameShort);
        });
        if (matched) matched.click();

        await sleep(3000);

        /* --- Step 3: Click the Download button --- */
        var btns = Array.from(document.querySelectorAll('button, a, [role="button"]'));
        var dlBtn = btns.find(function(b) {
            var t = (b.textContent || b.innerText || b.getAttribute('aria-label') || b.title || '').trim().toLowerCase();
            return /download|get lua|get fix|get bypass|inject/.test(t);
        });
        if (dlBtn) dlBtn.click();
    }

    run().catch(function () {});
})();
"@

# ---- Event Handlers ----
$script:captured = $false

$wv.add_CoreWebView2InitializationCompleted({
    param($s, $e)
    if (-not $e.IsSuccess) {
        $err = if ($e.InitializationException) { $e.InitializationException.Message } else { "Unknown WebView2 initialization error" }
        [System.IO.File]::WriteAllText($TempFile + ".error", "WebView2 Init Failed: $err. Please ensure Microsoft Edge / WebView2 Runtime is installed.")
        $form.Close()
        return
    }
    $lbl.Text = "  Browser ready. Installing ad-blocker & hooks..."
    $s.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync($interceptJs) | Out-Null

    # Block popups / new window requests (common ad triggers)
    $s.CoreWebView2.add_NewWindowRequested({
        param($s2, $e2)
        $e2.Handled = $true
    })

    # Block redirects to external ad/tracking networks (only allow openlua.cloud & Cloudflare)
    $s.CoreWebView2.add_NavigationStarting({
        param($s2, $e2)
        $uri = $e2.Uri
        if ($uri -notmatch 'openlua\.cloud' -and $uri -notmatch 'cloudflare' -and $uri -notmatch 'about:blank') {
            $e2.Cancel = $true
        }
    })

    $s.CoreWebView2.add_WebMessageReceived({
        param($s2, $e2)
        if ($script:captured) { return }
        try {
            $msg = $e2.WebMessageAsJson | ConvertFrom-Json
            if ($msg.type -eq 'LUA' -and $msg.content -match 'addappid') {
                $script:captured = $true
                $enc = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($TempFile, $msg.content, $enc)
                $lbl.Text = "  LUA captured! Closing browser..."
                $form.BeginInvoke([Action]{ Start-Sleep -Milliseconds 600; $form.Close() })
            }
        } catch {}
    })

    $s.CoreWebView2.Navigate("https://openlua.cloud/")
    $lbl.Text = "  Navigating to openlua.cloud..."
})

$wv.add_NavigationCompleted({
    param($s, $e)
    if ($script:captured) { return }
    $lbl.Text = "  Page loaded. Searching for $GameName ..."
    $s.ExecuteScriptAsync($triggerJs) | Out-Null
})

$form.add_Load({
    try {
        $wv.EnsureCoreWebView2Async() | Out-Null
    } catch {
        [System.IO.File]::WriteAllText($TempFile + ".error", "WebView2 Runtime Error: $($_.Exception.Message). Please install Microsoft Edge / WebView2 Runtime.")
        $form.Close()
    }
})

# ---- Auto-close after 45 seconds timeout ----
$timer           = New-Object System.Windows.Forms.Timer
$timer.Interval  = 45000
$timer.Add_Tick({
    $timer.Stop()
    if (-not $script:captured) {
        if (-not (Test-Path $TempFile) -and -not (Test-Path ($TempFile + ".error"))) {
            [System.IO.File]::WriteAllText($TempFile + ".error", "Fetch timed out after 45 seconds. Check internet connection or solve Turnstile captcha in browser.")
        }
        $form.Close()
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run($form)
