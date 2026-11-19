# Run once from the GUI. This opens one visible console for SSH password input.
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9.-]+$')][string]$RemoteHost,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$RemoteUser
)
# Creates an SSH key for unattended launches and installs a user systemd service.
$ErrorActionPreference = 'Stop'
$Remote = "${RemoteUser}@${RemoteHost}"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$KeyDir = Join-Path $env:USERPROFILE '.ssh'
$KeyFile = Join-Path $KeyDir 'dggs_mi100_ed25519'

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing $Name. Enable Windows OpenSSH Client in Optional Features."
    }
}

try {
    Require-Command 'ssh.exe'
    Require-Command 'scp.exe'
    Require-Command 'ssh-keygen.exe'
    New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null

    if (-not (Test-Path -LiteralPath $KeyFile)) {
        Write-Host 'Creating a dedicated SSH key for the one-click launcher...'
        & ssh-keygen.exe -q -t ed25519 -a 64 -N '""' -f $KeyFile
        if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed.' }
    }
    if (-not (Test-Path -LiteralPath "$KeyFile.pub")) {
        throw "Missing public key: $KeyFile.pub"
    }

    Write-Host ''
    Write-Host "Checking SSH key authentication on $Remote."
    Write-Host 'Verify the SSH host fingerprint if Windows asks you to trust a new host.'

    # Windows PowerShell 5.1 turns native SSH stderr into PowerShell error records.
    # With ErrorActionPreference=Stop, an EXPECTED failure of this first key test
    # previously aborted the script before the password fallback could run.
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & ssh.exe -T -i $KeyFile -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 $Remote 'true' 2>$null
        $keyAlreadyAuthorized = ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }

    if (-not $keyAlreadyAuthorized) {
        Write-Host ''
        Write-Host 'The DGGS SSH key is not authorized yet.' -ForegroundColor Yellow
        Write-Host 'SSH will ask for your university server login password once.'
        Write-Host 'Password characters will not appear while typing.'
        Write-Host 'Do NOT type your password into this script or a config file.'
        Write-Host ''
        # The public key is sent via standard input to the remote login shell.
        # Keep stderr non-terminating so SSH password prompts remain interactive.
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            Get-Content -LiteralPath "$KeyFile.pub" |
                & ssh.exe -T -o BatchMode=no -o ConnectTimeout=30 $Remote 'umask 077; mkdir -p ~/.ssh; chmod 700 ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'
            $installExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorPreference
        }
        if ($installExitCode -ne 0) {
            throw "Could not authorize the SSH key. Check Tailscale and login to $Remote using: ssh.exe $Remote"
        }
    }

    & ssh.exe -T -i $KeyFile -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=12 $Remote 'mkdir -p ~/dggs-ai/launcher'
    if ($LASTEXITCODE -ne 0) { throw 'SSH key authentication still failed after setup. Confirm the remote authorized_keys permissions.' }

    $InstallFile = Join-Path (Split-Path -Parent $Root) 'Server\install-router.sh'
    $RunFile = Join-Path (Split-Path -Parent $Root) 'Server\run-router.sh'
    if (-not (Test-Path -LiteralPath $InstallFile) -or -not (Test-Path -LiteralPath $RunFile)) {
        throw 'The Server scripts are missing. Extract the full ZIP before running Setup.'
    }

    Write-Host 'Copying the server service scripts...'
    & scp.exe -i $KeyFile -o BatchMode=yes $InstallFile $RunFile "${Remote}:dggs-ai/launcher/"
    if ($LASTEXITCODE -ne 0) { throw 'File transfer to the server failed.' }

    Write-Host 'Installing the server service without starting the model...'
    & ssh.exe -i $KeyFile -o BatchMode=yes $Remote 'chmod 700 ~/dggs-ai/launcher/*.sh && bash ~/dggs-ai/launcher/install-router.sh'
    if ($LASTEXITCODE -ne 0) { throw 'Remote installation failed. Review the error above.' }

    Write-Host ''
    Write-Host 'SETUP COMPLETE' -ForegroundColor Green
    Write-Host 'Return to the Control Center. Continue with Step 2, or click Start Everything.'
    Write-Host 'If an older llama-server is still running on 8080, stop that manual process once.'
    $SetupExit = 0
} catch {
    Write-Host ''
    Write-Host "SETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $SetupExit = 1
}
Write-Host ''
[void](Read-Host 'Press Enter to return to the Control Center')
exit $SetupExit

