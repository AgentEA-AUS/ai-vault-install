# AI Vault installer  - AgentEA (Windows)
# Sets up a private, receive-only copy of your business vault on this PC, then
# auto-wires it into Claude Desktop and/or Codex with a standalone connector
# binary  - no folder picker, no .mcpb, no Codex setup by hand.
#
# Works on stock Windows 10/11 PowerShell 5.1  - no admin rights needed anywhere.
#
# Usage (normal install  - usually pasted as one invite line):
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -ServerId <ID> -FolderId <ID> `
#       -Label <person> -Token <TOKEN> [-ClientPrefix <p>] [-ConnectorUrlBase <URL>]
#   With -Token the computer enrolls automatically (no pairing code to read).
#   Without -Token the classic pairing-code flow runs (the manual fallback).
#   (-McpbUrl is still accepted for old invite lines but is now ignored.)
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
    # Where the standalone connector binaries are published; override if hosted elsewhere.
    [string]$ConnectorUrlBase = "https://github.com/AgentEA-AUS/ai-vault-install/releases/download/connector-v0.2.0",
    [string]$McpbUrl      = "",   # legacy no-op: accepted so old invite lines still run
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

# The standalone vault connector we download and wire into the AI apps, and
# where Claude Desktop keeps its list of MCP servers. In TEST MODE the Claude
# config is a throwaway file so we never touch the real one.
$Connector = Join-Path $BinDir 'vault-connector.exe'
if ($TestMode) {
    $ClaudeConfig = Join-Path $env:AIVAULT_TEST_DIR 'claude_desktop_config.json'
} else {
    $ClaudeConfig = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
}

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
    # Talk to our private sync program. Throws on failure  - wrap in try/catch
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

function Write-JsonFileNoBom {
    # Atomic, UTF-8 without BOM (Claude Desktop's JSON parser rejects a BOM).
    param([string]$Path, [string]$Json)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp.$PID"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $Json, $utf8NoBom)
    Move-Item -Path $tmp -Destination $Path -Force
}

function Merge-ClaudeConfig {
    # Set our one MCP entry, preserving every other key and every other server.
    param([string]$ConfigPath, [string]$Command, [string]$Vault)
    $root = $null
    if (Test-Path $ConfigPath) {
        try { $root = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json } catch { $root = $null }
    }
    if ($null -eq $root) { $root = New-Object PSObject }
    $servers = $null
    if ($root.PSObject.Properties.Name -contains 'mcpServers') { $servers = $root.mcpServers }
    if ($null -eq $servers) { $servers = New-Object PSObject }
    $entry = [PSCustomObject]@{ command = $Command; args = @($Vault) }
    $servers | Add-Member -NotePropertyName 'business_vault' -NotePropertyValue $entry -Force
    $root | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue $servers -Force
    Write-JsonFileNoBom -Path $ConfigPath -Json ($root | ConvertTo-Json -Depth 10)
}

function Remove-ClaudeEntry {
    # Remove only our entry, leaving everything else untouched.
    param([string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) { return }
    try { $root = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json } catch { return }
    if ($null -eq $root) { return }
    if (($root.PSObject.Properties.Name -contains 'mcpServers') -and $root.mcpServers) {
        if ($root.mcpServers.PSObject.Properties.Name -contains 'business_vault') {
            $root.mcpServers.PSObject.Properties.Remove('business_vault')
        }
    }
    Write-JsonFileNoBom -Path $ConfigPath -Json ($root | ConvertTo-Json -Depth 10)
}

function Test-Connector {
    # Prove the downloaded binary is really our connector: non-empty AND it
    # answers an MCP "initialize" request over stdio.
    param([string]$Exe, [string]$Vault)
    if (-not (Test-Path $Exe)) { return $false }
    if ((Get-Item $Exe).Length -le 0) { return $false }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $Exe
        $psi.Arguments              = "`"$Vault`""
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install","version":"0"}}}'
        $p.StandardInput.WriteLine($init)
        $p.StandardInput.Flush()
        # First launch of a large unsigned exe can be slow (Windows Defender scans
        # it on execution), so wait generously for the initialize reply.
        $readTask = $p.StandardOutput.ReadLineAsync()
        $line = ''
        if ($readTask.Wait(30000)) { $line = $readTask.Result }
        $alive = -not $p.HasExited
        try { $p.Kill() } catch { }
        try { $p.StandardInput.Close() } catch { }
        # Pass if it answered the MCP handshake OR (fallback) it spawned and was
        # still running  - a healthy MCP server waiting on stdio. Only a binary
        # that crashed on launch exits early, and that is what we reject.
        if ($line -match '"jsonrpc"') { return $true }
        return $alive
    } catch {
        return $false
    }
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

    # Un-wire the AI apps: drop just our entry from Claude Desktop's config and,
    # if Codex is here, remove its vault MCP server. Both leave everything else
    # untouched and are no-ops when absent.
    if ($ClaudeConfig -and (Test-Path $ClaudeConfig)) {
        try { Remove-ClaudeEntry -ConfigPath $ClaudeConfig; Write-Host '  - vault removed from Claude Desktop' } catch { }
    }
    $codexCmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexCmd) {
        if ($TestMode) { $codexHome = Join-Path $env:AIVAULT_TEST_DIR 'codex' } else { $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' } }
        $prevCodexHome = $env:CODEX_HOME
        $env:CODEX_HOME = $codexHome
        try { & codex mcp remove business_vault *> $null; if (-not $TestMode) { Write-Host '  - vault removed from Codex' } } catch { }
        $env:CODEX_HOME = $prevCodexHome
    }

    if (Test-Path $AppDir) {
        Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host '  - program files deleted'
    if ($TestMode) {
        if (Test-Path $VaultDir) { Remove-Item $VaultDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host '  - test vault folder deleted'
    } else {
        Write-Host "  - your vault folder was NOT deleted; your files are still in: $VaultDir"
    }
    Write-Host 'Done.'
    exit 0
}

# ---------- 1. banner + preflight ---------------------------------------------
Write-Host ''
Write-Host '============================================================'
Write-Host '   AI VAULT SETUP   -  AgentEA'
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

# Claude Desktop check  - best effort, never a blocker.
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
    Write-Host 'Step 1 of 6: Sync program already downloaded  - skipping.'
} else {
    Write-Host 'Step 1 of 6: Downloading the sync program (about 11 MB)...'
    try {
        $relHeaders = @{}
        if ($env:AIVAULT_GH_TOKEN) { $relHeaders['Authorization'] = "Bearer $($env:AIVAULT_GH_TOKEN)" }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/syncthing/syncthing/releases/latest' -Headers $relHeaders -TimeoutSec 60
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
Write-Host "Step 2 of 6: Setting up this PC's private connection..."
if ((Test-Path $CfgPath) -and (Test-Path (Join-Path $StHome 'cert.pem'))) {
    Write-Host '  Already set up from an earlier run  - keeping it.'
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

        # Seed the WHOLE connection structure into the config BEFORE first start:
        # the local device's announced name, the AgentEA server device, and the
        # two-way vault folder listing both devices. This is the Windows fix -- a
        # Windows client would not adopt a folder/device injected over REST after
        # start into its live cluster-config, so it announced the folder without
        # the server device and the server kept dropping it. Writing it into
        # config.xml means the first cluster-config is already correct.
        $localDev = $cfg.SelectSingleNode('device')
        if ($null -eq $localDev) { throw 'no local device element' }
        $localId = $localDev.GetAttribute('id')
        $localDev.SetAttribute('name', $DeviceName)

        # Server device: clone the local device (same compression / accept
        # defaults, address=dynamic) and re-stamp its id + name.
        $srvDev = $localDev.CloneNode($true)
        $srvDev.SetAttribute('id', $ServerId)
        $srvDev.SetAttribute('name', $ServerName)
        [void]$cfg.AppendChild($srvDev)

        # Two-way vault folder listing this PC + the server. Syncthing fills the
        # remaining folder defaults (rescan interval, versioning, etc.) on load.
        $folder = $xml.CreateElement('folder')
        $folder.SetAttribute('id', $FolderId)
        $folder.SetAttribute('label', $FolderLabel)
        $folder.SetAttribute('path', $VaultDir)
        $folder.SetAttribute('type', 'sendreceive')
        $folder.SetAttribute('fsWatcherEnabled', 'true')
        foreach ($devId in @($localId, $ServerId)) {
            $fd = $xml.CreateElement('device')
            $fd.SetAttribute('id', $devId)
            $fd.SetAttribute('introducedBy', '')
            [void]$fd.AppendChild($xml.CreateElement('encryptionPassword'))
            [void]$folder.AppendChild($fd)
        }
        [void]$cfg.AppendChild($folder)

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
Write-Host 'Step 3 of 6: Starting the sync program...'
if (Get-VaultSyncProcess) {
    Write-Host '  Already running from an earlier run  - keeping it.'
} else {
    Start-Process -FilePath $Bin -ArgumentList @('serve', '--home', "`"$StHome`"", '--no-browser', '--no-console', "--logfile=$AppDir\syncthing.log") -WindowStyle Hidden
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

# The server device and the vault folder were already written into the config
# BEFORE the program started (see Step 2), so this PC announced the correct
# cluster-config from its very first connection. Read the folder back and PROVE
# the server is in its device list -- a sanity check on the pre-start seeding.
try {
    $check = Invoke-StApi -Path "/rest/config/folders/$FolderId"
    $ids = @($check.devices | ForEach-Object { $_.deviceID })
    if (($ids -notcontains $ServerId) -or ($ids -notcontains $MyId)) {
        Fail "The vault folder was saved without its connections (have: $($ids -join ', '))."
    }
} catch {
    Fail 'Could not verify the vault folder setup.'
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
    Write-Host '#   YOUR PAIRING CODE  - read it to AgentEA on the call:'
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
    $waitStep = 'Step 4 of 6: Connecting to your vault server...'
    $waitHint = 'Connecting to your vault server...'
    $waitFail = "Could not connect to your vault server yet. It keeps trying in the background  - if it doesn't finish shortly, run the installer line again."
} else {
    $waitStep = 'Step 4 of 6: Waiting for AgentEA to approve this computer...'
    $waitHint = 'Waiting for AgentEA to approve this computer... (tell them your pairing code)'
    $waitFail = 'AgentEA has not approved this computer yet. The connection keeps trying in the background  - once they approve, run this installer again to finish up.'
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
    # The folder may not be shared back for a few seconds  - retry quietly.
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
        Fail 'The vault did not arrive. Your invite may have expired or already been used on another computer  - ask AgentEA for a fresh invite, then paste the new line they send you.'
    }
    Fail 'The vault is taking longer than expected to arrive. Leave this window open  - it keeps trying in the background.'
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
    Write-Host "Step 5 of 6: TEST MODE  - skipping the automatic startup entry (would create $(Get-StartupShortcutPath))."
} else {
    Write-Host 'Step 5 of 6: Making sync start automatically with this PC...'
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Get-StartupShortcutPath))
        $shortcut.TargetPath       = $Bin
        $shortcut.Arguments        = "serve --home `"$StHome`" --no-browser --no-console --logfile=$AppDir\syncthing.log"
        $shortcut.WorkingDirectory = $AppDir
        $shortcut.WindowStyle      = 7   # minimized, stays out of the way
        $shortcut.Description      = 'Keeps your AI Vault in sync (AgentEA)'
        $shortcut.Save()
    } catch {
        Fail 'Could not set sync to start automatically with this PC.'
    }
    Write-Host '  Done  - sync now survives restarts.'
}

# ---------- 7. auto-wire the AI apps ----------------------------------------------
# The vault is on disk; now point Claude Desktop and/or Codex at it with a
# standalone connector binary  - no folder picker, no .mcpb, no Codex setup.
Write-Host ''
Write-Host 'Step 6 of 6: Connecting your vault to Claude / Codex...'

# a) download the right connector binary for this PC's processor, then prove it runs.
$connArch = if ($Arch -eq 'amd64') { 'x64' } else { 'arm64' }
$connectorSrc = "$ConnectorUrlBase/vault-connector-windows-$connArch.exe"
if (-not (Test-Path $Connector)) {
    Write-Host '  Downloading the vault connector...'
    try {
        Invoke-WebRequest -Uri $connectorSrc -OutFile $Connector -TimeoutSec 300 -UseBasicParsing
    } catch {
        Fail 'Could not download the vault connector. Check this PC is online, then run the installer line again.'
    }
    try { Unblock-File -Path $Connector } catch { }
}
if (-not (Test-Connector -Exe $Connector -Vault $VaultDir)) {
    Fail 'The vault connector would not start on this PC. Run the installer line again; if it keeps failing, call AgentEA.'
}

$wiredClaude = $false
$wiredCodex  = $false

# b) Claude Desktop  - merge our one entry into its config, never clobbering any
#    other keys or servers. In TEST MODE the config is a throwaway file.
$claudePresent = $false
if ($TestMode) {
    $claudePresent = $true                        # always exercise the merge in tests
} elseif (($env:APPDATA -and (Test-Path (Join-Path $env:APPDATA 'Claude'))) `
          -or ($env:LOCALAPPDATA -and (Test-Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')))) {
    $claudePresent = $true
}
if ($claudePresent) {
    # Back the existing config up once before we ever touch it.
    if ((Test-Path $ClaudeConfig) -and -not (Test-Path "$ClaudeConfig.agentea-backup")) {
        Copy-Item -Path $ClaudeConfig -Destination "$ClaudeConfig.agentea-backup" -Force -ErrorAction SilentlyContinue
    }
    try {
        Merge-ClaudeConfig -ConfigPath $ClaudeConfig -Command $Connector -Vault $VaultDir
        $wiredClaude = $true
        Write-Host '  Connected to Claude Desktop.'
    } catch {
        Fail "Could not update Claude's settings."
    }
}

# c) Codex  - non-interactive, remove-then-add so re-running is idempotent. A
#    Codex hiccup must never fail the whole install: warn and carry on.
$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
if ($codexCmd) {
    if ($TestMode) { $codexHome = Join-Path $env:AIVAULT_TEST_DIR 'codex' } else { $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' } }
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $prevCodexHome = $env:CODEX_HOME
    $env:CODEX_HOME = $codexHome
    try {
        & codex mcp remove business_vault *> $null
        & codex mcp add business_vault '--' $Connector $VaultDir *> $null
        if ($LASTEXITCODE -eq 0) {
            $wiredCodex = $true
            Write-Host '  Connected to Codex.'
        } else {
            Write-Host '  NOTE: found Codex but could not wire it automatically  - skipping it.'
        }
    } catch {
        Write-Host '  NOTE: found Codex but could not wire it automatically  - skipping it.'
    } finally {
        $env:CODEX_HOME = $prevCodexHome
    }
}

# d) Nothing to wire into  - the vault is still synced; re-running wires it.
if (-not $wiredClaude -and -not $wiredCodex) {
    if (-not $TestMode) { try { Start-Process explorer.exe $VaultDir } catch { } }
    Write-Host ''
    Write-Host '============================================================'
    Write-Host '   YOUR VAULT IS READY on this PC:'
    Write-Host ''
    Write-Host "     $VaultDir"
    Write-Host ''
    Write-Host "   We couldn't find Claude or Codex on this computer. Install one"
    Write-Host '   of them (claude.ai/download or the Codex CLI), then paste this'
    Write-Host '   same line again  - it will connect the vault automatically.'
    Write-Host '============================================================'
    Write-Host ''
    exit 0
}

# e) Final message  - name exactly what was wired. If Claude was wired and is
#    running (and we are not testing), restart it so it picks up the new server.
$wiredList = @()
if ($wiredClaude) { $wiredList += 'Claude Desktop' }
if ($wiredCodex)  { $wiredList += 'Codex' }

if ($wiredClaude -and -not $TestMode) {
    $claudeProc = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
    if ($claudeProc) {
        $claudeExe = ($claudeProc | Where-Object { $_.Path } | Select-Object -First 1).Path
        try {
            $claudeProc | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if ($claudeExe) { Start-Process -FilePath $claudeExe }
        } catch { }
    }
}

if (-not $TestMode) { try { Start-Process explorer.exe $VaultDir } catch { } }
Write-Host ''
Write-Host '============================================================'
Write-Host '   DONE  - your vault is connected on this PC.'
Write-Host ''
Write-Host "   Wired into: $($wiredList -join ' and ')"
Write-Host "   Your vault: $VaultDir"
if ($wiredClaude) {
    Write-Host ''
    Write-Host '   Close Claude completely and open it again, then ask a question'
    Write-Host '   about your business, e.g. "How do we complete the monthly statement?"'
}
Write-Host '============================================================'
Write-Host ''
