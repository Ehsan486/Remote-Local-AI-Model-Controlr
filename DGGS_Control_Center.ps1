# DGGS AI Control Center for Windows PowerShell 5.1.
# Native Windows Forms UI: no administrator rights or extra GUI software required.
# Only manages the user's own systemd user service on the AMD server.
# Does not stop unrelated processes or use sudo.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DataRoot = Join-Path $env:LOCALAPPDATA 'DGGSControlCenter'
$script:LogDir = Join-Path $script:DataRoot 'logs'
$script:StateDir = Join-Path $script:DataRoot 'state'
$script:ConfigPath = Join-Path $script:DataRoot 'settings.json'
$script:WebUIDir = Join-Path $env:USERPROFILE 'dggs-ai\ui'
$script:KeyFile = Join-Path $env:USERPROFILE '.ssh\dggs_mi100_ed25519'
$script:RouterUrl = 'http://127.0.0.1:18080'
$script:WebUIUrl = 'http://127.0.0.1:3000/'
$script:Busy = $false
$script:ApiJob = $null
$script:ApiJobAction = ''
$script:LastBackgroundPoll = [DateTime]::MinValue
$script:ModelValues = @('dggs-main', 'dggs-uncensored')
New-Item -ItemType Directory -Path $script:LogDir, $script:StateDir, $script:WebUIDir -Force | Out-Null

$script:Config = [ordered]@{ Server = ''; User = '' }
if (Test-Path -LiteralPath $script:ConfigPath) {
    try {
        $saved = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        if ($saved.Server -match '^[A-Za-z0-9.-]+$' -and $saved.User -match '^[A-Za-z0-9_.-]+$') {
            $script:Config.Server = [string]$saved.Server
            $script:Config.User = [string]$saved.User
        }
    } catch { }
}

function Color([string]$Hex) {
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

$script:C = @{
    Background = (Color '#101621')
    Surface = (Color '#192333')
    Surface2 = (Color '#223047')
    Main = (Color '#5AB5F5')
    Text = (Color '#F2F6FC')
    Muted = (Color '#A6B7CF')
    Green = (Color '#68DBA2')
    Amber = (Color '#F6C16A')
    Red = (Color '#FC777A')
}

function Add-Label($Parent, [string]$Caption, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Size, [bool]$Bold, $Foreground) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Caption
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new($W, $H)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = [System.Drawing.Font]::new('Segoe UI', [single]$Size, $style)
    $label.ForeColor = $Foreground
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.AutoEllipsis = $true
    $Parent.Controls.Add($label)
    return $label
}

function Add-Button($Parent, [string]$Caption, [int]$X, [int]$Y, [int]$W, [int]$H, $Background, [int]$FontSize = 10) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Caption
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($W, $H)
    $button.BackColor = $Background
    $button.ForeColor = $script:C.Text
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.UseVisualStyleBackColor = $false
    $button.Font = [System.Drawing.Font]::new('Segoe UI', [single]$FontSize, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Parent.Controls.Add($button)
    return $button
}

function Add-Panel($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, $Background) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = [System.Drawing.Point]::new($X, $Y)
    $panel.Size = [System.Drawing.Size]::new($W, $H)
    $panel.BackColor = $Background
    $Parent.Controls.Add($panel)
    return $panel
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'DGGS AI Control Center'
$script:Form.ClientSize = [System.Drawing.Size]::new(1110, 835)
$script:Form.BackColor = $script:C.Background
$script:Form.ForeColor = $script:C.Text
$script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$script:Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$script:Form.MaximizeBox = $false
$script:Form.MinimumSize = [System.Drawing.Size]::new(1126, 874)
$script:Form.Font = [System.Drawing.Font]::new('Segoe UI', [single]10)

Add-Label $script:Form 'DGGS  /  AI CONTROL CENTER' 24 18 850 36 22 $true $script:C.Text | Out-Null
Add-Label $script:Form 'Windows workstation  >  SSH tunnel  >  4 AMD MI100 GPUs  >  Open WebUI' 25 57 880 26 10 $false $script:C.Muted | Out-Null
$script:ButtonSettings = Add-Button $script:Form 'Settings' 965 25 119 36 $script:C.Surface2 10

$left = Add-Panel $script:Form 20 105 559 605 $script:C.Surface
$right = Add-Panel $script:Form 593 105 496 605 $script:C.Surface
Add-Label $left 'STARTUP STEPS' 22 18 370 30 13 $true $script:C.Text | Out-Null
Add-Label $left 'Click each action in order, or use Start Everything.' 22 48 510 25 9 $false $script:C.Muted | Out-Null

$steps = @(
    @{ title = '1   Initial Setup';       hint = 'One time only. Creates SSH key and server service.'; y = 91 },
    @{ title = '2   Check Connection';    hint = 'Checks the university server and SSH key.'; y = 172 },
    @{ title = '3   Connect Tunnel';      hint = 'Creates a private encrypted Windows connection.'; y = 253 },
    @{ title = '4   Start Model Server';  hint = 'Starts the router without preloading GPU weights.'; y = 334 },
    @{ title = '5   Start Open WebUI';    hint = 'Starts or reuses your local WebUI and data.'; y = 415 },
    @{ title = '6   Open Browser';       hint = 'Opens the research workspace in your browser.'; y = 496 }
)
$script:StepButtons = @()
foreach ($step in $steps) {
    $b = Add-Button $left $step.title 22 $step.y 207 53 $script:C.Surface2 10
    $script:StepButtons += $b
    Add-Label $left $step.hint 246 ($step.y + 9) 284 44 9 $false $script:C.Muted | Out-Null
}

Add-Label $right 'LIVE STATUS' 23 18 280 29 13 $true $script:C.Text | Out-Null
$script:RefreshButton = Add-Button $right 'Refresh' 370 17 105 31 $script:C.Surface2 9
$script:StatusSSH = Add-Label $right 'SSH: not checked' 24 62 448 25 10 $false $script:C.Muted
$script:StatusTunnel = Add-Label $right 'Tunnel: not checked' 24 90 448 25 10 $false $script:C.Muted
$script:StatusRouter = Add-Label $right 'GPU server: not checked' 24 118 448 25 10 $false $script:C.Muted
$script:StatusWeb = Add-Label $right 'Open WebUI: not checked' 24 146 448 25 10 $false $script:C.Muted
$script:StatusGPU = Add-Label $right 'GPU VRAM: use GPU Status to inspect' 24 174 448 25 10 $false $script:C.Muted
$script:GPUButton = Add-Button $right 'GPU Status' 355 205 119 35 $script:C.Surface2 9

Add-Label $right 'MODEL CONTROL' 23 215 320 28 12 $true $script:C.Text | Out-Null
$script:ComboModels = New-Object System.Windows.Forms.ComboBox
$script:ComboModels.Location = [System.Drawing.Point]::new(23, 250)
$script:ComboModels.Size = [System.Drawing.Size]::new(450, 32)
$script:ComboModels.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:ComboModels.Font = [System.Drawing.Font]::new('Segoe UI', [single]10)
foreach ($name in $script:ModelValues) { [void]$script:ComboModels.Items.Add($name) }
$script:ComboModels.SelectedIndex = 0
$right.Controls.Add($script:ComboModels)
$script:LoadButton = Add-Button $right 'Load Selected Model' 23 291 217 42 (Color '#116D83') 10
$script:UnloadButton = Add-Button $right 'Unload Selected Model' 253 291 220 42 (Color '#66543C') 10
$script:ModelStatus = Add-Label $right 'Models: not checked' 24 341 449 34 9 $false $script:C.Muted

Add-Label $right 'ACTIVITY LOG' 23 389 270 26 12 $true $script:C.Text | Out-Null
$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = [System.Drawing.Point]::new(23, 418)
$script:LogBox.Size = [System.Drawing.Size]::new(451, 169)
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:LogBox.ReadOnly = $true
$script:LogBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:LogBox.BackColor = $script:C.Background
$script:LogBox.ForeColor = $script:C.Muted
$script:LogBox.Font = [System.Drawing.Font]::new('Consolas', [single]9)
$right.Controls.Add($script:LogBox)

$script:StartAllButton = Add-Button $script:Form 'START EVERYTHING' 21 731 250 58 (Color '#087CA6') 12
$script:StopModelsButton = Add-Button $script:Form 'STOP MODELS / FREE GPU' 283 731 298 58 (Color '#A33C49') 11
$script:StopTunnelButton = Add-Button $script:Form 'Disconnect Tunnel' 593 731 206 58 $script:C.Surface2 10
$script:ExitButton = Add-Button $script:Form 'Exit' 813 731 276 58 $script:C.Surface2 10
$script:BottomStatus = Add-Label $script:Form 'Ready. Initial setup is needed only once.' 24 801 1060 22 9 $false $script:C.Muted

$script:ActionButtons = @($script:StepButtons) + @($script:RefreshButton, $script:GPUButton, $script:LoadButton, $script:UnloadButton, $script:StartAllButton, $script:StopTunnelButton, $script:ButtonSettings)

function Write-Log([string]$Message) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $entry = ('[{0}] {1}' -f $stamp, $Message)
    $script:LogBox.AppendText($entry + [Environment]::NewLine)
    $script:LogBox.SelectionStart = $script:LogBox.Text.Length
    $script:LogBox.ScrollToCaret()
    Add-Content -LiteralPath (Join-Path $script:LogDir 'control-center.log') -Value $entry
    $script:BottomStatus.Text = $Message
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Indicator($Label, [string]$Message, [string]$State) {
    $Label.Text = $Message
    switch ($State) {
        'ok'    { $Label.ForeColor = $script:C.Green }
        'error' { $Label.ForeColor = $script:C.Red }
        'busy'  { $Label.ForeColor = $script:C.Amber }
        default { $Label.ForeColor = $script:C.Muted }
    }
}

function Set-Busy([bool]$IsBusy) {
    $script:Busy = $IsBusy
    foreach ($button in $script:ActionButtons) { $button.Enabled = -not $IsBusy }
    # A background model load job leaves Busy false, so Stop remains available.
    $script:StopModelsButton.Enabled = -not $IsBusy
    [System.Windows.Forms.Application]::DoEvents()
}

function Wait-UI([int]$Milliseconds) {
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $Milliseconds) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Run-UIAction([string]$Name, [scriptblock]$Body) {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        Write-Log $Name
        & $Body
    } catch {
        $message = $_.Exception.Message
        Write-Log ('ERROR: ' + $message)
        [void][System.Windows.Forms.MessageBox]::Show($message, 'DGGS Control Center', 'OK', 'Error')
    } finally {
        Set-Busy $false
    }
}

function Test-Web([string]$Url, [int]$TimeoutSeconds = 3) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
    } catch {
        return $false
    }
}

function Require-ConnectionSettings {
    if (-not $script:Config.Server -or -not $script:Config.User) {
        throw 'Open Settings and enter the SSH server host and username first.'
    }
}

function Get-RemoteName {
    return ('{0}@{1}' -f $script:Config.User, $script:Config.Server)
}

function Test-TcpHost([string]$HostName, [int]$Port, [int]$TimeoutMs = 3500) {
    $client = New-Object System.Net.Sockets.TcpClient
    $asyncResult = $null
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($asyncResult)
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $asyncResult) { $asyncResult.AsyncWaitHandle.Close() }
        $client.Close()
    }
}

function Require-SSHKey {
    Require-ConnectionSettings
    if (-not (Test-Path -LiteralPath $script:KeyFile)) {
        throw 'SSH key not found. Click Step 1 Initial Setup once. This setup may open a password prompt.'
    }
    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
        throw 'Windows OpenSSH Client is missing. Install it from Windows Optional Features.'
    }
}

function Call-SSH([string]$RemoteCommand, [int]$Timeout = 12) {
    Require-SSHKey
    $remote = Get-RemoteName
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & ssh.exe -T -i $script:KeyFile -o BatchMode=yes -o ConnectTimeout=$Timeout -o ServerAliveInterval=15 $remote $RemoteCommand 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($exitCode -ne 0) {
        throw ('SSH command failed (exit {0}): {1}' -f $exitCode, $output.Trim())
    }
    return $output.Trim()
}

function Test-SSH {
    Require-ConnectionSettings
    if (-not (Test-TcpHost $script:Config.Server 22 3500)) {
        Set-Indicator $script:StatusSSH 'SSH: cannot reach the server (check Tailscale)' 'error'
        throw 'The SSH server is unreachable. Check that Tailscale is connected on both computers and try again.'
    }
    if (-not (Test-Path -LiteralPath $script:KeyFile)) {
        Set-Indicator $script:StatusSSH 'SSH: server reachable, setup required' 'busy'
        throw 'The university server is reachable, but the launcher SSH key is missing. Click Step 1.'
    }
    $response = Call-SSH 'printf DGGS_SSH_OK' 10
    if ($response -notmatch 'DGGS_SSH_OK') { throw 'The SSH verification response was unexpected.' }
    Set-Indicator $script:StatusSSH ('SSH: authenticated to ' + (Get-RemoteName)) 'ok'
    Write-Log 'SSH authentication succeeded.'
}

function Get-ManagedTunnel {
    $pidFile = Join-Path $script:StateDir 'tunnel.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $raw = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    $processId = 0
    if (-not [int]::TryParse($raw, [ref]$processId)) { return $null }
    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
        if ($null -ne $process -and $process.Name -ieq 'ssh.exe' -and $process.CommandLine -match '18080:127\.0\.0\.1:8080') {
            return $process
        }
    } catch { }
    return $null
}

function Test-LocalPort([int]$Port) {
    return (Test-TcpHost '127.0.0.1' $Port 1000)
}

function Start-Tunnel {
    Require-SSHKey
    if ($null -ne (Get-ManagedTunnel)) {
        Set-Indicator $script:StatusTunnel 'SSH tunnel: connected (managed)' 'ok'
        Write-Log 'Existing managed SSH tunnel reused.'
        return
    }
    if (Test-LocalPort 18080) {
        if (Test-Web ($script:RouterUrl + '/v1/models') 3) {
            Set-Indicator $script:StatusTunnel 'SSH tunnel: existing connection reused' 'ok'
            Write-Log 'Existing port 18080 connection reused. This application will not terminate it.'
            return
        }
        throw 'Port 18080 is already occupied. Close the old manual SSH tunnel or change its port before continuing.'
    }
    $remote = Get-RemoteName
    $argsText = '-N -T -L 127.0.0.1:18080:127.0.0.1:8080 -i "' + $script:KeyFile + '" -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 ' + $remote
    $logFile = Join-Path $script:LogDir 'ssh-tunnel-error.log'
    $process = Start-Process -FilePath 'ssh.exe' -ArgumentList $argsText -WindowStyle Hidden -PassThru -RedirectStandardError $logFile
    Set-Content -LiteralPath (Join-Path $script:StateDir 'tunnel.pid') -Value $process.Id
    Wait-UI 2200
    $process.Refresh()
    if ($process.HasExited) {
        $tail = if (Test-Path -LiteralPath $logFile) { (Get-Content $logFile -Tail 12 | Out-String).Trim() } else { 'No SSH log.' }
        throw ('SSH tunnel exited. Check Tailscale, SSH key or port conflict. ' + $tail)
    }
    Set-Indicator $script:StatusTunnel 'SSH tunnel: connected on localhost:18080' 'ok'
    Write-Log 'SSH tunnel started. No separate terminal is needed.'
}

function Start-GPUService {
    if (-not (Test-LocalPort 18080)) { throw 'Click Step 3 Connect Tunnel first.' }
    Set-Indicator $script:StatusRouter 'GPU server: starting...' 'busy'
    $command = 'if systemctl --user is-active --quiet dggs-llama.service; then echo ALREADY_RUNNING; elif ss -ltn | grep -q ":8080 "; then echo PORT_8080_OCCUPIED; exit 23; else systemctl --user start dggs-llama.service; fi; systemctl --user is-active dggs-llama.service'
    $out = Call-SSH $command 15
    Write-Log ('Server: ' + $out.Replace([Environment]::NewLine, ' '))
    for ($i = 0; $i -lt 80; $i++) {
        if (Test-Web ($script:RouterUrl + '/models') 3) {
            Set-Indicator $script:StatusRouter 'GPU server: online (models load on demand)' 'ok'
            Write-Log 'Model router is online. No GPU weights need to be loaded yet.'
            Refresh-Models
            return
        }
        if (($i % 10) -eq 0) { $script:BottomStatus.Text = 'Starting GPU server; waiting for router...' }
        Wait-UI 1000
    }
    throw 'The user service started but the router is not responding. Inspect remote journalctl logs.'
}

function Find-UVX {
    $item = Get-Command uvx.exe -ErrorAction SilentlyContinue
    if ($null -ne $item) { return $item.Source }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\uvx.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    throw 'uvx.exe is missing. Install uv on Windows before starting Open WebUI.'
}

function Start-WebUI {
    if (Test-Web $script:WebUIUrl 3) {
        Set-Indicator $script:StatusWeb 'Open WebUI: running on localhost:3000' 'ok'
        Write-Log 'Reusing existing Open WebUI. Chats and settings remain unchanged.'
        return
    }
    # Reuse the installed application runtime while retaining this dashboard's
    # separate DATA_DIR, signing key, and university model-router settings.
    $installedWebUI = 'C:\LocalAI\OpenWebUI\.venv\Scripts\open-webui.exe'
    if (Test-Path -LiteralPath $installedWebUI) {
        $webUICommand = $installedWebUI
        $webUIArguments = @('serve', '--host', '127.0.0.1', '--port', '3000')
    } else {
        $webUICommand = Find-UVX
        $webUIArguments = @('--link-mode', 'copy', '--python', '3.12', 'open-webui@0.13.0', 'serve', '--host', '127.0.0.1', '--port', '3000')
    }
    $env:DATA_DIR = Join-Path $script:WebUIDir 'data'
    $env:OPENAI_API_BASE_URL = $script:RouterUrl + '/v1'
    $env:OPENAI_API_KEY = 'local'
    $env:ENABLE_OLLAMA_API = 'false'
    New-Item -ItemType Directory -Path $env:DATA_DIR -Force | Out-Null
    $stdout = Join-Path $script:LogDir 'open-webui-output.log'
    $stderr = Join-Path $script:LogDir 'open-webui-error.log'
    # Copy mode avoids Windows cloud-files hardlink error 396. Keep the installed
    # application version stable; starting the dashboard must not upgrade it.
    $process = Start-Process -FilePath $webUICommand -ArgumentList $webUIArguments -WorkingDirectory $script:WebUIDir -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Set-Content -LiteralPath (Join-Path $script:StateDir 'webui.pid') -Value $process.Id
    Set-Indicator $script:StatusWeb 'Open WebUI: starting...' 'busy'
    for ($i = 0; $i -lt 150; $i++) {
        if (Test-Web $script:WebUIUrl 3) {
            Set-Indicator $script:StatusWeb 'Open WebUI: running on localhost:3000' 'ok'
            Write-Log 'Open WebUI is available.'
            return
        }
        $process.Refresh()
        if ($process.HasExited) {
            $tail = if (Test-Path -LiteralPath $stderr) { (Get-Content $stderr -Tail 12 | Out-String).Trim() } else { '' }
            throw ('Open WebUI startup exited with code ' + $process.ExitCode + '. ' + $tail)
        }
        if (($i % 12) -eq 0) { $script:BottomStatus.Text = 'Starting Open WebUI. Existing data directory is preserved.' }
        Wait-UI 1000
    }
    $tail = if (Test-Path -LiteralPath $stderr) { (Get-Content $stderr -Tail 12 | Out-String).Trim() } else { '' }
    throw ('Open WebUI did not become ready. See logs. ' + $tail)
}

function Open-WebUIBrowser {
    if (-not (Test-Web $script:WebUIUrl 4)) { throw 'Start Open WebUI first (Step 5).' }
    Start-Process $script:WebUIUrl | Out-Null
    Write-Log 'Opened Open WebUI in your default browser.'
}

function Refresh-Models {
    if (-not (Test-Web ($script:RouterUrl + '/models') 3)) {
        Set-Indicator $script:StatusRouter 'GPU server: offline or unreachable' 'error'
        $script:ModelStatus.Text = 'Models: router is not responding.'
        return
    }
    try {
        $models = Invoke-RestMethod -Uri ($script:RouterUrl + '/models') -TimeoutSec 6
        $lines = @()
        $found = @()
        foreach ($item in @($models.data)) {
            $name = [string]$item.id
            $state = [string]$item.status.value
            $lines += ('{0}: {1}' -f $name, $state)
            $found += $name
        }
        if ($lines.Count -eq 0) {
            $script:ModelStatus.Text = 'Models: none listed. Check the server presets.'
        } else {
            $script:ModelStatus.Text = ($lines -join '     ')
        }
        $script:ComboModels.Items.Clear()
        foreach ($name in $found) { [void]$script:ComboModels.Items.Add($name) }
        if ($found.Count -gt 0) { $script:ComboModels.SelectedIndex = 0 }
        Set-Indicator $script:StatusRouter 'GPU server: online, model router ready' 'ok'
    } catch {
        $script:ModelStatus.Text = 'Models: could not read statuses.'
    }
}

function Refresh-Status {
    $keyPresent = Test-Path -LiteralPath $script:KeyFile
    if (-not $script:Config.Server -or -not $script:Config.User) {
        Set-Indicator $script:StatusSSH 'SSH: enter connection details in Settings' 'neutral'
    } elseif ($keyPresent) {
        Set-Indicator $script:StatusSSH 'SSH: setup key found (not tested)' 'neutral'
    } else {
        Set-Indicator $script:StatusSSH 'SSH: initial setup required' 'busy'
    }
    $managed = Get-ManagedTunnel
    if ($null -ne $managed) {
        Set-Indicator $script:StatusTunnel 'SSH tunnel: managed process running' 'ok'
    } elseif (Test-Web ($script:RouterUrl + '/v1/models') 2) {
        Set-Indicator $script:StatusTunnel 'SSH tunnel: existing connection available' 'ok'
    } else {
        Set-Indicator $script:StatusTunnel 'SSH tunnel: not connected' 'neutral'
    }
    if (Test-Web $script:WebUIUrl 2) {
        Set-Indicator $script:StatusWeb 'Open WebUI: running on localhost:3000' 'ok'
    } else {
        Set-Indicator $script:StatusWeb 'Open WebUI: not running' 'neutral'
    }
    if (Test-Web ($script:RouterUrl + '/models') 2) { Refresh-Models }
    else { Set-Indicator $script:StatusRouter 'GPU server: stopped or tunnel unavailable' 'neutral'; $script:ModelStatus.Text = 'Models: offline' }
}

function Get-GPUStatus {
    $output = Call-SSH 'rocm-smi' 15
    $gpuLines = @($output -split "`n" | Where-Object { $_ -match '^\s*[0-3]\s+\d+\s+' })
    if ($gpuLines.Count -gt 0) {
        Write-Log 'GPU status from ROCm:'
        $percentages = @()
        foreach ($line in $gpuLines) {
            Write-Log $line.Trim()
            if ($line -match '^\s*([0-3])\s+\d+.*?\s+(\d+)%\s+\d+%\s*$') {
                $percentages += ('GPU {0}: {1}%' -f $Matches[1], $Matches[2])
            }
        }
        if ($percentages.Count -gt 0) {
            $script:StatusGPU.Text = 'GPU VRAM: ' + ($percentages -join '   ')
        } else {
            $script:StatusGPU.Text = ('GPU VRAM: see ' + $gpuLines.Count + ' readings in log')
        }
        $script:StatusGPU.ForeColor = $script:C.Main
    } else {
        Write-Log ('ROCm status: ' + $output)
        $script:StatusGPU.Text = 'GPU VRAM: see activity log'
    }
}

function Stop-Models {
    Set-Indicator $script:StatusRouter 'GPU server: stopping managed service...' 'busy'
    $output = Call-SSH 'systemctl --user stop dggs-llama.service; systemctl --user is-active dggs-llama.service || true' 18
    if ($output -notmatch '(?m)^inactive\s*$|(?m)^failed\s*$') {
        Write-Log ('Service state: ' + $output)
        throw 'The model server stop could not be verified. Check systemctl --user status dggs-llama.service.'
    }
    Set-Indicator $script:StatusRouter 'GPU server: stopped (managed GPU allocations released)' 'ok'
    $script:ModelStatus.Text = 'Models: stopped. Open WebUI is preserved.'
    Write-Log 'Managed model service stopped; its model processes have exited.'
    Write-Log 'If VRAM is still in use, another process may be using the GPUs.'
    Wait-UI 1500
    try { Get-GPUStatus } catch { Write-Log ('GPU status unavailable: ' + $_.Exception.Message) }
}

function Stop-Tunnel {
    $process = Get-ManagedTunnel
    if ($null -eq $process) {
        Write-Log 'No managed SSH tunnel was found. An external tunnel will not be stopped.'
        return
    }
    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
    Remove-Item -LiteralPath (Join-Path $script:StateDir 'tunnel.pid') -Force -ErrorAction SilentlyContinue
    Set-Indicator $script:StatusTunnel 'SSH tunnel: disconnected' 'neutral'
    Write-Log 'Managed SSH tunnel disconnected.'
}

function Start-ModelApiJob([string]$Operation) {
    if ($null -ne $script:ApiJob) {
        throw 'Another model load/unload request is in progress. Wait for that operation to finish.'
    }
    if (-not (Test-Web ($script:RouterUrl + '/models') 3)) {
        throw 'Start the secure tunnel and model server before using model controls.'
    }
    if ($null -eq $script:ComboModels.SelectedItem) { throw 'No model is selected or available.' }
    $model = [string]$script:ComboModels.SelectedItem
    $url = $script:RouterUrl + '/models/' + $Operation
    $script:ApiJob = Start-Job -ArgumentList @($url, $model) -ScriptBlock {
        param($Uri, $ModelId)
        $ErrorActionPreference = 'Stop'
        $json = @{ model = $ModelId } | ConvertTo-Json -Compress
        $result = Invoke-RestMethod -Method Post -Uri $Uri -Body $json -ContentType 'application/json' -TimeoutSec 900
        if (-not $result.success) { throw ('Router did not confirm ' + $ModelId) }
        Write-Output ($ModelId + ': successful')
    }
    $script:ApiJobAction = $Operation
    Set-Indicator $script:StatusRouter ('GPU server: ' + $Operation + ' ' + $model + '...') 'busy'
    Write-Log ('Started ' + $Operation + ' for ' + $model + '. The UI will remain responsive.')
}

function Check-ModelJob {
    if ($null -eq $script:ApiJob) { return }
    $status = $script:ApiJob.State
    if ($status -eq 'Running' -or $status -eq 'NotStarted') { return }
    $result = Receive-Job -Job $script:ApiJob -ErrorAction SilentlyContinue | Out-String
    $errorText = ($script:ApiJob.ChildJobs | ForEach-Object { $_.Error | Out-String }) -join ''
    if ($status -eq 'Completed') {
        Write-Log ('Model ' + $script:ApiJobAction + ' completed. ' + $result.Trim())
    } else {
        Write-Log ('Model ' + $script:ApiJobAction + ' failed: ' + $errorText.Trim())
        [void][System.Windows.Forms.MessageBox]::Show('The model operation failed. Review the activity log.', 'DGGS model operation', 'OK', 'Warning')
    }
    Remove-Job -Job $script:ApiJob -Force -ErrorAction SilentlyContinue
    $script:ApiJob = $null
    $script:ApiJobAction = ''
    Refresh-Models
}

function Do-Setup {
    Require-ConnectionSettings
    $setup = Join-Path $script:Root 'Windows\Setup-DGGS.ps1'
    if (-not (Test-Path -LiteralPath $setup)) { throw 'Setup-DGGS.ps1 missing. Extract the entire ZIP.' }
    Write-Log 'Opening the one-time interactive SSH setup window. Verify the SSH host fingerprint.'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $setup + '" -RemoteHost ' + $script:Config.Server + ' -RemoteUser ' + $script:Config.User
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -WindowStyle Normal
    while (-not $process.HasExited) { Wait-UI 250; $process.Refresh() }
    if ($process.ExitCode -ne 0) { throw 'Setup did not complete. Review the setup window error and run Step 1 again.' }
    if (-not (Test-Path -LiteralPath $script:KeyFile)) { throw 'Setup reported success, but no dedicated SSH private key was found.' }
    Write-Log 'One-time setup succeeded. Proceed to Step 2.'
    Refresh-Status
}

function Do-StartEverything {
    Require-ConnectionSettings
    if (-not (Test-Path -LiteralPath $script:KeyFile)) {
        throw 'First click Step 1 Initial Setup. The one-time password authorization cannot be done silently.'
    }
    Test-SSH
    Start-Tunnel
    Start-GPUService
    Start-WebUI
    Open-WebUIBrowser
    Write-Log 'Workspace ready. Select a model in Open WebUI or use Load Selected Model here.'
}

function Edit-Settings {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'DGGS Connection Settings'
    $dialog.Size = [System.Drawing.Size]::new(470, 258)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    Add-Label $dialog 'University server host' 17 16 410 23 10 $false ([System.Drawing.Color]::Black) | Out-Null
    $hostInput = New-Object System.Windows.Forms.TextBox
    $hostInput.Location = [System.Drawing.Point]::new(17, 43)
    $hostInput.Size = [System.Drawing.Size]::new(420, 26)
    $hostInput.Text = $script:Config.Server
    $dialog.Controls.Add($hostInput)
    Add-Label $dialog 'SSH username' 17 83 410 23 10 $false ([System.Drawing.Color]::Black) | Out-Null
    $userInput = New-Object System.Windows.Forms.TextBox
    $userInput.Location = [System.Drawing.Point]::new(17, 109)
    $userInput.Size = [System.Drawing.Size]::new(420, 26)
    $userInput.Text = $script:Config.User
    $dialog.Controls.Add($userInput)
    $save = Add-Button $dialog 'Save' 235 157 96 35 (Color '#087CA6') 10
    $cancel = Add-Button $dialog 'Cancel' 341 157 96 35 (Color '#495B73') 10
    $save.Add_Click({
        if ($hostInput.Text -notmatch '^[A-Za-z0-9.-]+$' -or $userInput.Text -notmatch '^[A-Za-z0-9_.-]+$') {
            [void][System.Windows.Forms.MessageBox]::Show('Host or username contains invalid characters.', 'Invalid setting', 'OK', 'Warning')
            return
        }
        $script:Config.Server = $hostInput.Text
        $script:Config.User = $userInput.Text
        $script:Config | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $cancel.Add_Click({ $dialog.Close() })
    [void]$dialog.ShowDialog($script:Form)
}

# Explicit button actions. No automatic use of the university GPUs on application startup.
$script:StepButtons[0].Add_Click({ Run-UIAction 'Initial SSH and service setup' { Do-Setup } })
$script:StepButtons[1].Add_Click({ Run-UIAction 'Checking server over Tailscale' { Test-SSH } })
$script:StepButtons[2].Add_Click({ Run-UIAction 'Connecting secure tunnel' { Start-Tunnel } })
$script:StepButtons[3].Add_Click({ Run-UIAction 'Starting GPU model manager' { Start-GPUService } })
$script:StepButtons[4].Add_Click({ Run-UIAction 'Starting Open WebUI' { Start-WebUI } })
$script:StepButtons[5].Add_Click({ Run-UIAction 'Opening browser' { Open-WebUIBrowser } })
$script:RefreshButton.Add_Click({ Run-UIAction 'Refreshing status' { Refresh-Status } })
$script:GPUButton.Add_Click({ Run-UIAction 'Reading MI100 GPU memory' { Get-GPUStatus } })
$script:LoadButton.Add_Click({ Run-UIAction 'Loading selected model' { Start-ModelApiJob 'load' } })
$script:UnloadButton.Add_Click({ Run-UIAction 'Unloading selected model' { Start-ModelApiJob 'unload' } })
$script:StartAllButton.Add_Click({ Run-UIAction 'Starting complete DGGS workspace' { Do-StartEverything } })
$script:StopModelsButton.Add_Click({ Run-UIAction 'Stopping managed models and freeing GPU memory' { Stop-Models } })
$script:StopTunnelButton.Add_Click({ Run-UIAction 'Disconnecting managed tunnel' { Stop-Tunnel } })
$script:ButtonSettings.Add_Click({ Run-UIAction 'Editing connection settings' { Edit-Settings } })
$script:ExitButton.Add_Click({ $script:Form.Close() })

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 1000
$script:Timer.Add_Tick({
    if ($null -ne $script:ApiJob) { Check-ModelJob }
    if (-not $script:Busy -and $null -eq $script:ApiJob -and ([DateTime]::Now - $script:LastBackgroundPoll).TotalSeconds -gt 20) {
        $script:LastBackgroundPoll = [DateTime]::Now
        if (Test-Web ($script:RouterUrl + '/models') 2) { Refresh-Models }
    }
})
$script:Timer.Start()
$script:Form.Add_FormClosing({
    param($sender, $closingArgs)
    # Ask before leaving the GPU router running on a shared university server.
    if (Test-Web ($script:RouterUrl + '/models') 2) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            'The AMD model server is still reachable. Stop your managed models and release their GPU memory before closing?  Yes = stop models; No = leave running; Cancel = stay here.',
            'Release GPU memory before exit?',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
            $closingArgs.Cancel = $true
            return
        }
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Stop-Models
            } catch {
                [void][System.Windows.Forms.MessageBox]::Show(
                    ('Could not verify that the managed models stopped. The panel will remain open. ' + $_.Exception.Message),
                    'Stop failed', 'OK', 'Error'
                )
                $closingArgs.Cancel = $true
                return
            }
        }
    }
    $script:Timer.Stop()
    if ($null -ne $script:ApiJob) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'A model operation is still in progress. If you left the model server running, you may need to stop it later to free GPU memory.',
            'DGGS Control Center', 'OK', 'Information'
        )
    }
})

Write-Log 'Control Center opened. No model or GPU job has been started.'
Refresh-Status
[void]$script:Form.ShowDialog()
