# AI Vault installer — AgentEA (Windows)
# Sets up a private, receive-only copy of your business vault on this PC and
# opens the AI-Vault extension installer for Claude Desktop.
#
# Works on stock Windows 10/11 PowerShell 5.1 — no admin rights needed anywhere.
#
# Usage (normal install — usually pasted as one invite line):
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -ServerId <ID> -FolderId <ID> `
#       -Label <person> -Token <TOKEN> [-ClientPrefix <p>] [-McpbUrl <URL>]
#   With -Token the computer enrolls automatically (no pairing code to read).
#   Without -Token the classic pairing-code flow runs (the manual fallback).
#
# Remove it again (keeps your vault folder):
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# ============ PER-CLIENT SETTINGS (defaults; flags override) ================
param(
    [string]$ServerId     = "N737W2E-EBIAKPP-WSDDOB7-G4G6OHY-6LLOLP4-45OHFSL-NOJ3RVY-HKEZ2QF",
    [string]$FolderId     = "tb-vault",
    [string]$Label        = "",
    [string]$Token        = "",
    [string]$ClientPrefix = "tb",
    [string]$McpbUrl      = "",
    [switch]$Uninstall
)
$ServerName  = "AgentEA Vault Server"
$FolderLabel = "AI Vault"
# ============================================================================
# Nothing below this line is client-specific.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # big speed-up for downloads on PS 5.1

# PS 5.1 defaults to old TLS; GitHub requires TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------- fixed locations & ports -----------------------------------------
$AppDir       = Join-Path $env:LOCALAPPDATA 'AgentEA\AI-Vault'
$VaultDir     = Join-Path $env:USERPROFILE 'AI-Vault'
$GuiPort      = 8385      # local control port (custom, so we never clash with a
$ListenPort   = 22001     # normal Syncthing someone may already have installed)
$ShortcutName = 'AgentEA AI Vault.lnk'
$WaitTimeout  = 900       # seconds to wait for approval / for the vault to arrive
if ($env:AIVAULT_WAIT_TIMEOUT) { $WaitTimeout = [int]$env:AIVAULT_WAIT_TIMEOUT }
$TestMode = $false
$NameMid  = ''            # "TEST-" in test mode, empty otherwise

# ---------- test mode: full rehearsal in a throwaway folder ------------------
if ($env:AIVAULT_TEST_MODE -eq '1') {
    $TestMode = $true
    if (-not $env:AIVAULT_TEST_DIR) {
        Write-Host 'TEST MODE needs AIVAULT_TEST_DIR to be set.'
        exit 1
    }
    $AppDir     = Join-Path $env:AIVAULT_TEST_DIR 'app'
    $VaultDir   = Join-Path $env:AIVAULT_TEST_DIR 'vault'
    $GuiPort    = 8386
    $ListenPort = 22002
    $NameMid    = 'TEST-'
}

$BinDir  = Join-Path $AppDir 'bin'
$Bin     = Join-Path $BinDir 'syncthing.exe'
$StHome  = Join-Path $AppDir 'syncthing-home'
$CfgPath = Join-Path $StHome 'config.xml'
$ApiUrl  = "http://127.0.0.1:$GuiPort"

# ---------- work out this computer's name on the server ----------------------
# With a token, the device announces itself as enroll:<token>:<base> so the
# server-side daemon can match the token, approve it, and rename it to <base>.
$HostShort = ''
if ($env:COMPUTERNAME) { $HostShort = ($env:COMPUTERNAME -replace '[^A-Za-z0-9-]', '') }
if (-not $HostShort) { $HostShort = 'pc' }
if ($Label) {
    $BaseDeviceName = "$ClientPrefix-$Label-$NameMid$HostShort"
} else {
    $BaseDeviceName = "$ClientPrefix-$NameMid$HostShort"
}
if ($Token) {
    $DeviceName = "enroll:${Token}:$BaseDeviceName"
} else {
    $DeviceName = $BaseDeviceName
}

# ---------- helpers ----------------------------------------------------------
function Fail([string]$Message) {
    Write-Host ''
    Write-Host "  PROBLEM: $Message"
    Write-Host '  ...call AgentEA and read them this message.'
    Write-Host ''
    exit 1
}

$script:ApiKey = ''
function Invoke-StApi {
    # Talk to our private sync program. Throws on failure — wrap in try/catch
    # when a failure is expected (e.g. polling before it's up).
    param(
        [string]$Method = 'Get',
        [Parameter(Mandatory = $true)][string]$Path,
        $Body = $null
    )
    $p = @{
        Method      = $Method
        Uri         = "$ApiUrl$Path"
        Headers     = @{ 'X-API-Key' = $script:ApiKey }
        TimeoutSec  = 10
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $p['Body']        = ($Body | ConvertTo-Json -Depth 6)
        $p['ContentType'] = 'application/json'
    }
    Invoke-RestMethod @p
}

function Get-VaultSyncProcess {
    # Our syncthing and only ours: match the process by its --home argument.
    Get-CimInstance Win32_Process -Filter "Name='syncthing.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$StHome*" }
}

function Stop-VaultSyncProcess {
    foreach ($proc in @(Get-VaultSyncProcess)) {
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 2
}

function Get-StartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) $ShortcutName
}

# ---------- uninstall --------------------------------------------------------
if ($Uninstall) {
    Write-Host 'Removing AI Vault sync from this PC...'
    $lnk = Get-StartupShortcutPath
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force -ErrorAction SilentlyContinue
        Write-Host '  - automatic startup entry removed'
    }
    Stop-VaultSyncProcess
    Write-Host '  - sync program stopped'
    if (Test-Path $AppDir) {
        Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host '  - program files deleted'
    if ($TestMode) {
        if (Test-Path $VaultDir) { Remove-Item $VaultDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host '  - test vault folder deleted'
    } else {
        Write-Host "  - your vault folder was NOT deleted; your files are still in: $VaultDir"
        Write-Host '  - if the AI Vault extension was added to Claude Desktop, remove it there'
        Write-Host '    yourself: Claude Desktop > Settings > Extensions > AI Vault > Remove.'
    }
    Write-Host 'Done.'
    exit 0
}

# ---------- 1. banner + preflight ---------------------------------------------
Write-Host ''
Write-Host '============================================================'
Write-Host '   AI VAULT SETUP  —  AgentEA'
Write-Host '   We are going to connect this PC to your business vault.'
Write-Host '   This takes about 5 minutes. Leave this window open.'
Write-Host '============================================================'
Write-Host ''
if ($TestMode) {
    Write-Host ">>> TEST MODE: everything happens inside $($env:AIVAULT_TEST_DIR) <<<"
    Write-Host ''
}

if ($env:OS -ne 'Windows_NT') {
    Fail 'This installer only works on a Windows PC. On a Mac or Linux computer, use the install.sh line instead.'
}

# Claude Desktop check — best effort, never a blocker.
$claudeFound = $false
if ($env:LOCALAPPDATA -and (Test-Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'))) {
    $claudeFound = $true
}
if (-not $claudeFound) {
    try {
        foreach ($menu in @([Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('CommonStartMenu'))) {
            if ($menu -and (Get-ChildItem -Path $menu -Recurse -Filter 'Claude*.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                $claudeFound = $true
                break
            }
        }
    } catch { }
}
if (-not $claudeFound) {
    Write-Host '  NOTE: The Claude app does not look installed yet. Setup will still work,'
    Write-Host '  but you will need Claude Desktop (claude.ai/download) for the last step.'
    Write-Host ''
}

# ---------- 2. download the sync program ---------------------------------------
switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $Arch = 'amd64' }
    'ARM64' { $Arch = 'arm64' }
    default { Fail "This PC has an unusual processor type ($($env:PROCESSOR_ARCHITECTURE))." }
}

# Never sync into a folder that already holds unrelated files. A folder from
# a previous run of THIS kit is fine (the sync program leaves a .stfolder
# marker inside it); anything else needs the person to move it first.
if ((Test-Path $VaultDir) `
    -and @(Get-ChildItem -Path $VaultDir -Force -ErrorAction SilentlyContinue).Count -gt 0 `
    -and -not (Test-Path (Join-Path $VaultDir '.stfolder')) `
    -and ($env:AIVAULT_FORCE_DIR -ne '1')) {
    Fail "There is already a folder at $VaultDir that has other files in it. We won't touch it. Please move or rename that folder, then run the installer again."
}

New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
New-Item -ItemType Directory -Path $VaultDir -Force | Out-Null

if (Test-Path $Bin) {
    Write-Host 'Step 1 of 5: Sync program already downloaded — skipping.'
} else {
    Write-Host 'Step 1 of 5: Downloading the sync program (about 11 MB)...'
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/syncthing/syncthing/releases/latest' -TimeoutSec 60
    } catch {
        Fail 'Could not reach the download site. Check this PC is online, then run the installer again.'
    }
    $asset = $release.assets | Where-Object { $_.name -like "syncthing-windows-$Arch-*.zip" } | Select-Object -First 1
    if (-not $asset) { Fail 'Could not find the right download for this PC.' }

    $dlTmp = Join-Path $env:TEMP ("aivault-" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $dlTmp -Force | Out-Null
    $zipPath = Join-Path $dlTmp 'syncthing.zip'
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -TimeoutSec 300 -UseBasicParsing
    } catch {
        Remove-Item $dlTmp -Recurse -Force -ErrorAction SilentlyContinue
        Fail 'The download failed part-way. Check this PC is online, then run the installer again.'
    }
    try {
        Expand-Archive -Path $zipPath -DestinationPath (Join-Path $dlTmp 'unpacked') -Force
    } catch {
        Remove-Item $dlTmp -Recurse -Force -ErrorAction SilentlyContinue
        Fail 'The downloaded file would not open.'
    }
    $foundBin = Get-ChildItem -Path (Join-Path $dlTmp 'unpacked') -Recurse -Filter 'syncthing.exe' | Select-Object -First 1
    if (-not $foundBin) {
        Remove-Item $dlTmp -Recurse -Force -ErrorAction SilentlyContinue
        Fail 'The download did not contain the sync program.'
    }
    Move-Item -Path $foundBin.FullName -Destination $Bin -Force
    Remove-Item $dlTmp -Recurse -Force -ErrorAction SilentlyContinue
    # Tell Windows this downloaded program is OK to run.
    try { Unblock-File -Path $Bin } catch { }
    Write-Host '  Downloaded.'
}

# ---------- 3. create this PC's private identity + settings --------------------
Write-Host "Step 2 of 5: Setting up this PC's private connection..."
if ((Test-Path $CfgPath) -and (Test-Path (Join-Path $StHome 'cert.pem'))) {
    Write-Host '  Already set up from an earlier run — keeping it.'
} else {
    # PS 5.1 quirk: redirecting a native command's error output while
    # $ErrorActionPreference is 'Stop' can throw a bogus NativeCommandError.
    # Relax it just for this call.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Bin generate --home $StHome *> $null
    $genExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($genExit -ne 0 -or -not (Test-Path $CfgPath)) {
        Fail "Could not create this PC's private connection files."
    }

    # Edit the freshly generated settings BEFORE first start, so we never come
    # up on the default ports (which could clash with another copy of Syncthing
    # already on this PC). "generate" picks random ports if the defaults are
    # busy, so these edits replace whatever value is there.
    try {
        $xml = [xml](Get-Content -Path $CfgPath -Raw)
        $cfg = $xml.configuration

        # Local control address.
        $guiAddr = $cfg.gui.SelectSingleNode('address')
        if ($null -eq $guiAddr) {
            $guiAddr = $xml.CreateElement('address')
            [void]$cfg.gui.AppendChild($guiAddr)
        }
        $guiAddr.InnerText = "127.0.0.1:$GuiPort"

        # Options: fixed sync port + the public relay network as fallback,
        # no LAN announcements, no usage reporting, no self-upgrades.
        $opts = $cfg.SelectSingleNode('options')
        if ($null -eq $opts) {
            $opts = $xml.CreateElement('options')
            [void]$cfg.AppendChild($opts)
        }
        foreach ($node in @($opts.SelectNodes('listenAddress'))) { [void]$opts.RemoveChild($node) }
        foreach ($addr in @("tcp://0.0.0.0:$ListenPort", "quic://0.0.0.0:$ListenPort", 'dynamic+https://relays.syncthing.net/endpoint')) {
            $el = $xml.CreateElement('listenAddress')
            $el.InnerText = $addr
            [void]$opts.AppendChild($el)
        }
        foreach ($pair in @(
            @('localAnnounceEnabled', 'false'),
            @('urAccepted', '-1'),
            @('autoUpgradeIntervalH', '0')
        )) {
            $node = $opts.SelectSingleNode($pair[0])
            if ($null -eq $node) {
                $node = $xml.CreateElement($pair[0])
                [void]$opts.AppendChild($node)
            }
            $node.InnerText = $pair[1]
        }

        # Drop the sample folder the sync program creates by default, so it
        # never makes a stray Sync folder. (The template inside <defaults>
        # has id="" and stays.)
        foreach ($node in @($cfg.SelectNodes("folder[@id='default']"))) { [void]$cfg.RemoveChild($node) }

        $xml.Save($CfgPath)
    } catch {
        Fail 'Could not adjust the connection settings.'
    }
}

try {
    $script:ApiKey = ([xml](Get-Content -Path $CfgPath -Raw)).configuration.gui.apikey
} catch { $script:ApiKey = '' }
if (-not $script:ApiKey) { Fail "Could not read this PC's private access key." }

# ---------- 4. start the sync program -------------------------------------------
Write-Host 'Step 3 of 5: Starting the sync program...'
if (Get-VaultSyncProcess) {
    Write-Host '  Already running from an earlier run — keeping it.'
} else {
    Start-Process -FilePath $Bin -ArgumentList @('serve', '--home', "`"$StHome`"", '--no-browser', '--no-console') -WindowStyle Hidden
}

# Wait for it to answer locally (up to 60 seconds).
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-StApi -Path '/rest/system/status' | Out-Null
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}
if (-not $ready) { Fail 'The sync program started but is not responding. Try closing this window and running the installer again.' }

$MyId = ''
try { $MyId = (Invoke-StApi -Path '/rest/system/status').myID } catch { }
if ($MyId -notmatch '^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$') { Fail "Could not read this PC's pairing code." }

# Name this PC, add the AgentEA server, and set up the vault folder
# (receive-only: this PC only ever RECEIVES the vault, it cannot change the
# master copy). Safe to repeat — re-running just re-applies the same thing.
try {
    Invoke-StApi -Method Patch -Path "/rest/config/devices/$MyId" -Body @{ name = $DeviceName } | Out-Null
} catch {
    Fail "Could not name this PC's connection."
}
try {
    Invoke-StApi -Method Put -Path "/rest/config/devices/$ServerId" -Body @{
        deviceID          = $ServerId
        name              = $ServerName
        addresses         = @('dynamic')
        introducer        = $false
        autoAcceptFolders = $false
    } | Out-Null
} catch {
    Fail 'Could not register the AgentEA server.'
}
try {
    Invoke-StApi -Method Put -Path "/rest/config/folders/$FolderId" -Body @{
        id               = $FolderId
        label            = $FolderLabel
        path             = $VaultDir
        type             = 'receiveonly'
        fsWatcherEnabled = $true
        devices          = @(
            @{ deviceID = $MyId },
            @{ deviceID = $ServerId }
        )
    } | Out-Null
} catch {
    Fail 'Could not set up the vault folder.'
}

# ---------- enrol / pairing notice ---------------------------------------------
Write-Host ''
if ($Token) {
    # Self-serve: the server approves this computer automatically once it sees
    # the one-time code built into the invite. Nothing to read to anyone.
    Write-Host '  Enrolling this computer automatically... no code to read out.'
    Write-Host "  (support reference, only if AgentEA asks: $MyId)"
} else {
    Write-Host '############################################################'
    Write-Host '#'
    Write-Host '#   YOUR PAIRING CODE — read it to AgentEA on the call:'
    Write-Host '#'
    Write-Host "#   $MyId"
    Write-Host '#'
    Write-Host '############################################################'
}
Write-Host ''

# ---------- 5. wait for approval, then receive the vault -------------------------
# With a token the server approves us on its own, so the honest wording is
# "connecting". Without one, a human is approving the pairing code by hand.
if ($Token) {
    $waitStep = 'Step 4 of 5: Connecting to your vault server...'
    $waitHint = 'Connecting to your vault server...'
    $waitFail = "Could not connect to your vault server yet. It keeps trying in the background — if it doesn't finish shortly, run the installer line again."
} else {
    $waitStep = 'Step 4 of 5: Waiting for AgentEA to approve this computer...'
    $waitHint = 'Waiting for AgentEA to approve this computer... (tell them your pairing code)'
    $waitFail = 'AgentEA has not approved this computer yet. The connection keeps trying in the background — once they approve, run this installer again to finish up.'
}
Write-Host $waitStep
$connected = $false
$elapsed = 0
while ($elapsed -lt $WaitTimeout) {
    try {
        $conns = Invoke-StApi -Path '/rest/system/connections'
        $entry = $null
        if ($conns -and $conns.connections) { $entry = $conns.connections.PSObject.Properties[$ServerId] }
        if ($entry -and $entry.Value.connected) {
            $connected = $true
            break
        }
    } catch { }
    Write-Host -NoNewline "`r  $waitHint  [${elapsed}s]"
    Start-Sleep -Seconds 5
    $elapsed += 5
}
Write-Host ''

if (-not $connected) { Fail $waitFail }
Write-Host '  Approved and connected.'

Write-Host '  Receiving your vault...'
$synced = $false
$elapsed = 0   # the vault transfer gets its own full time budget
while ($elapsed -lt $WaitTimeout) {
    $resp = $null
    try { $resp = Invoke-StApi -Path "/rest/db/completion?folder=$FolderId" } catch { }
    # The folder may not be shared back for a few seconds — retry quietly.
    # We also wait for globalBytes > 0: an empty, not-yet-shared folder
    # reports 100% even though nothing has arrived yet.
    if ($resp -and $resp.globalBytes -gt 0) {
        $comp = [math]::Floor([double]$resp.completion)
        Write-Host -NoNewline "`r  Receiving your vault... $comp%          "
        if ($comp -ge 100) {
            $synced = $true
            break
        }
    }
    Start-Sleep -Seconds 3
    $elapsed += 3
}
Write-Host ''

if (-not $synced) {
    if ($Token) {
        Fail 'The vault did not arrive. Your invite may have expired or already been used on another computer — ask AgentEA for a fresh invite, then paste the new line they send you.'
    }
    Fail 'The vault is taking longer than expected to arrive. Leave this window open — it keeps trying in the background.'
}
Write-Host "  Your vault has arrived: $VaultDir"

# ---------- drop the one-time token from this computer's name --------------------
# The token lived only inside our device name so the server could match it.
# Now that we're synced, rename ourselves to the plain label so the token
# never lingers in the local config.
if ($Token) {
    try {
        Invoke-StApi -Method Patch -Path "/rest/config/devices/$MyId" -Body @{ name = $BaseDeviceName } | Out-Null
    } catch { }
}

# ---------- 6. keep it running after restarts ------------------------------------
if ($TestMode) {
    Write-Host "Step 5 of 5: TEST MODE — skipping the automatic startup entry (would create $(Get-StartupShortcutPath))."
} else {
    Write-Host 'Step 5 of 5: Making sync start automatically with this PC...'
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Get-StartupShortcutPath))
        $shortcut.TargetPath       = $Bin
        $shortcut.Arguments        = "serve --home `"$StHome`" --no-browser --no-console"
        $shortcut.WorkingDirectory = $AppDir
        $shortcut.WindowStyle      = 7   # minimized, stays out of the way
        $shortcut.Description      = 'Keeps your AI Vault in sync (AgentEA)'
        $shortcut.Save()
    } catch {
        Fail 'Could not set sync to start automatically with this PC.'
    }
    Write-Host '  Done — sync now survives restarts.'
}

# ---------- 7. open the Claude Desktop extension ----------------------------------
if ($TestMode) {
    Write-Host 'TEST MODE: would now fetch the AI-Vault extension and open it in Claude Desktop.'
} else {
    $mcpbPath = Join-Path $env:USERPROFILE 'Downloads\AI-Vault.mcpb'
    if (-not $McpbUrl) { Fail 'The address of the AI-Vault extension is missing from this invite. Ask AgentEA for a fresh invite line.' }
    Write-Host ''
    Write-Host 'Fetching the Claude extension...'
    try {
        Invoke-WebRequest -Uri $McpbUrl -OutFile $mcpbPath -TimeoutSec 120 -UseBasicParsing
        try { Unblock-File -Path $mcpbPath } catch { }
    } catch {
        Fail 'Could not download the AI-Vault extension. Check this PC is online, then run the installer line again.'
    }
    try {
        Start-Process -FilePath $mcpbPath
    } catch {
        Fail 'Could not open the AI-Vault extension. Is Claude Desktop installed? Get it from claude.ai/download, then double-click AI-Vault.mcpb in your Downloads folder.'
    }
}

Write-Host ''
Write-Host '============================================================'
Write-Host '   NEARLY DONE — two clicks left, in the Claude window:'
Write-Host ''
Write-Host '   1. Click the Install button.'
Write-Host '   2. When it asks for your Vault folder, choose:'
Write-Host "      $VaultDir"
Write-Host ''
Write-Host '   Then ask Claude your first question, for example:'
Write-Host '   "What do you know about my business?"'
Write-Host '============================================================'
Write-Host ''
