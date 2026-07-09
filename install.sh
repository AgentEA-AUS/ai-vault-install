#!/bin/bash
#
# AI Vault installer — AgentEA
# Sets up a private, receive-only copy of your business vault on this Mac
# and opens the AI-Vault extension installer for Claude Desktop.
#
# Usage:
#   bash install.sh              normal install (run this on the call)
#   bash install.sh --uninstall  remove everything except your vault folder
#
# Self-serve invite mode (flags override the per-client defaults below, so the
# same script works both from a client zip AND from a one-line curl invite):
#   bash install.sh --server-id <ID> --folder-id <ID> --label <person> \
#                   --token <TOKEN> [--client-prefix <p>] [--mcpb-url <URL>]
#   With --token the computer enrolls automatically (no pairing code to read).
#   Without --token the classic pairing-code flow runs (the manual fallback).
#
# ============ PER-CLIENT SETTINGS (edit before zipping) ====================
SERVER_DEVICE_ID="N737W2E-EBIAKPP-WSDDOB7-G4G6OHY-6LLOLP4-45OHFSL-NOJ3RVY-HKEZ2QF"
SERVER_NAME="AgentEA Vault Server"
FOLDER_ID="tb-vault"
FOLDER_LABEL="AI Vault"
VAULT_DIR="$HOME/AI-Vault"
CLIENT_LABEL_PREFIX="tb"        # device name becomes tb-<hostname>
# ===========================================================================
# Nothing below this line is client-specific.

set -u

# ---------- flags: override the per-client defaults above -------------------
# These let one script serve both flows: a pre-built client zip (no flags,
# uses the TB defaults above) and a one-line curl invite (flags carry the
# per-person server id, folder, label and one-time token).
LABEL=""            # the person, e.g. donna — added into the device name
TOKEN=""            # one-time enrolment token; when set, auto-enrol (no code)
MCPB_URL=""         # where to fetch the Claude extension if it's not adjacent
UNINSTALL=0
while [ $# -gt 0 ]; do
    opt="$1"
    if [ "$opt" = "--uninstall" ]; then UNINSTALL=1; shift; continue; fi
    val="${2:-}"
    [ -n "$val" ] || { echo "Option $opt needs a value." >&2; exit 1; }
    case "$opt" in
        --server-id)     SERVER_DEVICE_ID="$val" ;;
        --folder-id)     FOLDER_ID="$val" ;;
        --label)         LABEL="$val" ;;
        --token)         TOKEN="$val" ;;
        --client-prefix) CLIENT_LABEL_PREFIX="$val" ;;
        --mcpb-url)      MCPB_URL="$val" ;;
        *) echo "Unknown option: $opt" >&2; exit 1 ;;
    esac
    shift 2
done

# ---------- fixed locations & ports ----------------------------------------
APP_DIR="$HOME/Library/Application Support/AgentEA/AI-Vault"
GUI_PORT=8385          # local control port (custom, so we never clash with a
LISTEN_PORT=22001      # normal Syncthing someone may already have installed)
LAUNCH_LABEL="com.agentea.aivault.syncthing"
PLIST="$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9-')"
WAIT_TIMEOUT="${AIVAULT_WAIT_TIMEOUT:-900}"   # seconds to wait for approval/sync
TEST_MODE=0
NAME_MID=""            # "TEST-" in test mode, empty otherwise

# ---------- test mode: full rehearsal in a throwaway folder ----------------
if [ "${AIVAULT_TEST_MODE:-0}" = "1" ]; then
    TEST_MODE=1
    if [ -z "${AIVAULT_TEST_DIR:-}" ]; then
        echo "TEST MODE needs AIVAULT_TEST_DIR to be set." >&2
        exit 1
    fi
    APP_DIR="$AIVAULT_TEST_DIR/app"
    VAULT_DIR="$AIVAULT_TEST_DIR/vault"
    GUI_PORT=8386
    LISTEN_PORT=22002
    NAME_MID="TEST-"
fi

# ---------- work out this computer's name on the server --------------------
# BASE_DEVICE_NAME is what the server shows once enrolment finishes.
# With a token, the device announces itself as enroll:<token>:<base> so the
# server-side daemon can match the token, approve it, and rename it to <base>.
if [ -n "$LABEL" ]; then
    BASE_DEVICE_NAME="${CLIENT_LABEL_PREFIX}-${LABEL}-${NAME_MID}${HOSTNAME_SHORT:-mac}"
else
    BASE_DEVICE_NAME="${CLIENT_LABEL_PREFIX}-${NAME_MID}${HOSTNAME_SHORT:-mac}"
fi
if [ -n "$TOKEN" ]; then
    DEVICE_NAME="enroll:${TOKEN}:${BASE_DEVICE_NAME}"
else
    DEVICE_NAME="$BASE_DEVICE_NAME"
fi

BIN_DIR="$APP_DIR/bin"
BIN="$BIN_DIR/syncthing"
ST_HOME="$APP_DIR/syncthing-home"
LOG="$APP_DIR/syncthing.log"
API_URL="http://127.0.0.1:$GUI_PORT"

# ---------- helpers ---------------------------------------------------------
die() {
    echo ""
    echo "  PROBLEM: $1"
    echo "  ...call AgentEA and read them this message."
    echo ""
    exit 1
}

api() {  # api <curl-args...>  — talk to our private sync program
    curl -fsS -m 10 -H "X-API-Key: $API_KEY" "$@" 2>/dev/null
}

# ---------- uninstall -------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
    echo "Removing AI Vault sync from this Mac..."
    if [ "$TEST_MODE" = "0" ] && [ -f "$PLIST" ]; then
        launchctl unload "$PLIST" 2>/dev/null
        rm -f "$PLIST"
        echo "  - background sync service removed"
    fi
    pkill -f "$ST_HOME" 2>/dev/null && sleep 2
    pkill -9 -f "$ST_HOME" 2>/dev/null
    echo "  - sync program stopped"
    rm -rf "$APP_DIR"
    echo "  - program files deleted"
    if [ "$TEST_MODE" = "1" ]; then
        rm -rf "$VAULT_DIR"
        echo "  - test vault folder deleted"
    else
        echo "  - your vault folder was NOT deleted; your files are still in: $VAULT_DIR"
        echo "  - if the AI Vault extension was added to Claude Desktop, remove it there"
        echo "    yourself: Claude Desktop > Settings > Extensions > AI Vault > Remove."
    fi
    echo "Done."
    exit 0
fi

# ---------- 1. banner + preflight -------------------------------------------
echo ""
echo "============================================================"
echo "   AI VAULT SETUP  —  AgentEA"
echo "   We are going to connect this Mac to your business vault."
echo "   This takes about 5 minutes. Leave this window open."
echo "============================================================"
echo ""
if [ "$TEST_MODE" = "1" ]; then
    echo ">>> TEST MODE: everything happens inside $AIVAULT_TEST_DIR <<<"
    echo ""
fi

[ "$(uname -s)" = "Darwin" ] || die "This installer only works on a Mac."
command -v curl >/dev/null 2>&1 || die "This Mac is missing a standard tool (curl) that should always be there."
if [ ! -d "/Applications/Claude.app" ]; then
    echo "  NOTE: The Claude app is not installed yet. Setup will still work,"
    echo "  but you will need Claude Desktop (claude.ai/download) for the last step."
    echo ""
fi

# ---------- 2. download the sync program ------------------------------------
case "$(uname -m)" in
    arm64)  ARCH="arm64" ;;
    x86_64) ARCH="amd64" ;;
    *)      die "This Mac has an unusual processor type ($(uname -m))." ;;
esac

# Never sync into a folder that already holds unrelated files. A folder from
# a previous run of THIS kit is fine (the sync program leaves a .stfolder
# marker inside it); anything else needs the person to move it first.
if [ -d "$VAULT_DIR" ] && [ -n "$(ls -A "$VAULT_DIR" 2>/dev/null)" ] \
   && [ ! -e "$VAULT_DIR/.stfolder" ] && [ "${AIVAULT_FORCE_DIR:-0}" != "1" ]; then
    die "There is already a folder at $VAULT_DIR that has other files in it. We won't touch it. Please move or rename that folder, then run the installer again."
fi

mkdir -p "$BIN_DIR" "$VAULT_DIR"

if [ -x "$BIN" ]; then
    echo "Step 1 of 5: Sync program already downloaded — skipping."
else
    echo "Step 1 of 5: Downloading the sync program (about 11 MB)..."
    RELEASE_JSON="$(curl -fsSL -m 60 "https://api.github.com/repos/syncthing/syncthing/releases/latest")" \
        || die "Could not reach the download site. Check this Mac is online, then run the installer again."
    ASSET_URL="$(printf '%s' "$RELEASE_JSON" \
        | grep -o '"browser_download_url": *"[^"]*"' \
        | sed 's/.*"\(https:[^"]*\)"/\1/' \
        | grep "syncthing-macos-${ARCH}-" | head -1)"
    [ -n "$ASSET_URL" ] || die "Could not find the right download for this Mac."

    DL_TMP="$(mktemp -d)"
    curl -fsSL -m 300 -o "$DL_TMP/syncthing.zip" "$ASSET_URL" \
        || { rm -rf "$DL_TMP"; die "The download failed part-way. Check this Mac is online, then run the installer again."; }
    unzip -q -o "$DL_TMP/syncthing.zip" -d "$DL_TMP/unpacked" \
        || { rm -rf "$DL_TMP"; die "The downloaded file would not open."; }
    FOUND_BIN="$(find "$DL_TMP/unpacked" -type f -name syncthing | head -1)"
    [ -n "$FOUND_BIN" ] || { rm -rf "$DL_TMP"; die "The download did not contain the sync program."; }
    mv "$FOUND_BIN" "$BIN"
    chmod +x "$BIN"
    rm -rf "$DL_TMP"
    # Tell macOS this downloaded program is OK to run (ignore if already OK).
    xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
    echo "  Downloaded."
fi

# ---------- 3. create this Mac's private identity + settings -----------------
echo "Step 2 of 5: Setting up this Mac's private connection..."
if [ -f "$ST_HOME/config.xml" ] && [ -f "$ST_HOME/cert.pem" ]; then
    echo "  Already set up from an earlier run — keeping it."
else
    "$BIN" generate --home "$ST_HOME" >/dev/null 2>&1 \
        || die "Could not create this Mac's private connection files."
    CFG="$ST_HOME/config.xml"
    [ -f "$CFG" ] || die "The connection settings file was not created."

    # Edit the freshly generated settings BEFORE first start, so we never
    # come up on the default ports (which could clash with another copy
    # of Syncthing already on this Mac). Note: "generate" picks random
    # ports if the defaults are busy, so these edits must replace whatever
    # value is there, not assume the default.
    sed -i '' \
        -e "/<gui /,/<\/gui>/ s|<address>[^<]*</address>|<address>127.0.0.1:$GUI_PORT</address>|" \
        -e "s|<localAnnounceEnabled>[^<]*</localAnnounceEnabled>|<localAnnounceEnabled>false</localAnnounceEnabled>|" \
        -e "s|<urAccepted>[^<]*</urAccepted>|<urAccepted>-1</urAccepted>|" \
        -e "s|<autoUpgradeIntervalH>[^<]*</autoUpgradeIntervalH>|<autoUpgradeIntervalH>0</autoUpgradeIntervalH>|" \
        "$CFG" || die "Could not adjust the connection settings."

    # Replace ALL generated listen addresses with our fixed custom port
    # (plus the public relay network as fallback).
    awk -v tcp="tcp://0.0.0.0:$LISTEN_PORT" -v quic="quic://0.0.0.0:$LISTEN_PORT" '
        /<listenAddress>/ {
            if (!done) {
                match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH)
                print ind "<listenAddress>" tcp "</listenAddress>"
                print ind "<listenAddress>" quic "</listenAddress>"
                print ind "<listenAddress>dynamic+https://relays.syncthing.net/endpoint</listenAddress>"
                done = 1
            }
            next
        }
        {print}
    ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG" \
        || die "Could not set the connection port."

    # Drop the sample folder the sync program creates by default,
    # so it never makes a stray ~/Sync folder.
    awk '
        /<folder id="default"[^>]*\/>/ {next}
        /<folder id="default"/ {skip=1}
        skip && /<\/folder>/ {skip=0; next}
        !skip {print}
    ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
fi

API_KEY="$(sed -n 's/.*<apikey>\(.*\)<\/apikey>.*/\1/p' "$ST_HOME/config.xml" | head -1)"
[ -n "$API_KEY" ] || die "Could not read this Mac's private access key."

# ---------- 4. start the sync program ----------------------------------------
echo "Step 3 of 5: Starting the sync program..."
NOHUP_PID=""
if pgrep -f "$ST_HOME" >/dev/null 2>&1; then
    echo "  Already running from an earlier run — keeping it."
else
    nohup "$BIN" serve --home "$ST_HOME" --no-browser > "$LOG" 2>&1 &
    NOHUP_PID=$!
fi

# Wait for it to answer locally (up to 60 seconds).
READY=0
for _ in $(seq 1 60); do
    if api "$API_URL/rest/system/status" >/dev/null; then READY=1; break; fi
    sleep 1
done
[ "$READY" = "1" ] || die "The sync program started but is not responding. Try closing this window and running the installer again."

MY_ID="$(api "$API_URL/rest/system/status" | grep -o '"myID"[^,]*' | sed 's/.*"\([A-Z0-9-]\{50,\}\)".*/\1/')"
echo "$MY_ID" | grep -Eq '^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$' \
    || die "Could not read this Mac's pairing code."

# Name this Mac, add the AgentEA server, and set up the vault folder
# (receive-only: this Mac only ever RECEIVES the vault, it cannot change
# the master copy). Safe to repeat — re-running just re-applies the same thing.
api -X PATCH -H "Content-Type: application/json" \
    -d "{\"name\":\"$DEVICE_NAME\"}" \
    "$API_URL/rest/config/devices/$MY_ID" >/dev/null \
    || die "Could not name this Mac's connection."

api -X PUT -H "Content-Type: application/json" \
    -d "{\"deviceID\":\"$SERVER_DEVICE_ID\",\"name\":\"$SERVER_NAME\",\"addresses\":[\"dynamic\"],\"introducer\":false,\"autoAcceptFolders\":false}" \
    "$API_URL/rest/config/devices/$SERVER_DEVICE_ID" >/dev/null \
    || die "Could not register the AgentEA server."

api -X PUT -H "Content-Type: application/json" \
    -d "{\"id\":\"$FOLDER_ID\",\"label\":\"$FOLDER_LABEL\",\"path\":\"$VAULT_DIR\",\"type\":\"receiveonly\",\"fsWatcherEnabled\":true,\"devices\":[{\"deviceID\":\"$MY_ID\"},{\"deviceID\":\"$SERVER_DEVICE_ID\"}]}" \
    "$API_URL/rest/config/folders/$FOLDER_ID" >/dev/null \
    || die "Could not set up the vault folder."

# ---------- enrol / pairing notice -------------------------------------------
echo ""
if [ -n "$TOKEN" ]; then
    # Self-serve: the server approves this computer automatically once it sees
    # the one-time code built into the invite. Nothing to read to anyone.
    echo "  Enrolling this computer automatically... no code to read out."
    echo "  (support reference, only if AgentEA asks: $MY_ID)"
else
    echo "############################################################"
    echo "#"
    echo "#   YOUR PAIRING CODE — read it to AgentEA on the call:"
    echo "#"
    echo "#   $MY_ID"
    echo "#"
    echo "############################################################"
fi
echo ""

# ---------- 5. wait for approval, then receive the vault ----------------------
# With a token the server approves us on its own, so the honest wording is
# "connecting". Without one, a human is approving the pairing code by hand.
if [ -n "$TOKEN" ]; then
    WAIT_STEP="Step 4 of 5: Connecting to your vault server..."
    WAIT_HINT="Connecting to your vault server..."
    WAIT_FAIL="Could not connect to your vault server yet. It keeps trying in the background — if it doesn't finish shortly, run the installer line again."
else
    WAIT_STEP="Step 4 of 5: Waiting for AgentEA to approve this computer..."
    WAIT_HINT="Waiting for AgentEA to approve this computer... (tell them your pairing code)"
    WAIT_FAIL="AgentEA has not approved this computer yet. The connection keeps trying in the background — once they approve, run this installer again to finish up."
fi
echo "$WAIT_STEP"
CONNECTED=0
ELAPSED=0
while [ "$ELAPSED" -lt "$WAIT_TIMEOUT" ]; do
    # The reply is pretty-printed JSON — squash whitespace before matching.
    if api "$API_URL/rest/system/connections" | tr -d ' \n\t' \
        | grep -o "\"$SERVER_DEVICE_ID\":{.\{0,250\}" \
        | grep -q '"connected":true'; then
        CONNECTED=1
        break
    fi
    printf '\r  %s  [%ss]' "$WAIT_HINT" "$ELAPSED"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
echo ""

if [ "$CONNECTED" != "1" ]; then
    die "$WAIT_FAIL"
fi
echo "  Approved and connected."

echo "  Receiving your vault..."
SYNCED=0
ELAPSED=0   # the vault transfer gets its own full time budget
while [ "$ELAPSED" -lt "$WAIT_TIMEOUT" ]; do
    RESP="$(api "$API_URL/rest/db/completion?folder=$FOLDER_ID" | tr -d ' \n\t')" || RESP=""
    COMP="$(printf '%s' "$RESP" | grep -o '"completion":[0-9.]*' | head -1 | sed 's/.*://' | sed 's/\..*//')"
    GLOB="$(printf '%s' "$RESP" | grep -o '"globalBytes":[0-9]*' | head -1 | sed 's/.*://')"
    # The folder may not be shared back for a few seconds — retry quietly.
    # We also wait for globalBytes > 0: an empty, not-yet-shared folder
    # reports 100% even though nothing has arrived yet.
    if [ -n "$COMP" ] && [ -n "$GLOB" ] && [ "$GLOB" -gt 0 ]; then
        printf '\r  Receiving your vault... %s%%          ' "$COMP"
        if [ "$COMP" -ge 100 ]; then SYNCED=1; break; fi
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
done
echo ""

if [ "$SYNCED" != "1" ]; then
    if [ -n "$TOKEN" ]; then
        die "The vault did not arrive. Your invite may have expired or already been used on another computer — ask AgentEA for a fresh invite, then paste the new line they send you."
    fi
    die "The vault is taking longer than expected to arrive. Leave this window open — it keeps trying in the background."
fi
echo "  Your vault has arrived: $VAULT_DIR"

# ---------- drop the one-time token from this computer's name -----------------
# The token lived only inside our device name so the server could match it.
# Now that we're synced, rename ourselves to the plain label so the token
# never lingers in the local config.
if [ -n "$TOKEN" ]; then
    api -X PATCH -H "Content-Type: application/json" \
        -d "{\"name\":\"$BASE_DEVICE_NAME\"}" \
        "$API_URL/rest/config/devices/$MY_ID" >/dev/null 2>&1 || true
fi

# ---------- 6. keep it running after restarts --------------------------------
if [ "$TEST_MODE" = "1" ]; then
    echo "Step 5 of 5: TEST MODE — skipping the always-on service (would install $PLIST)."
else
    echo "Step 5 of 5: Making sync start automatically with this Mac..."
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LAUNCH_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>serve</string>
        <string>--home</string>
        <string>$ST_HOME</string>
        <string>--no-browser</string>
        <string>--no-restart</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$APP_DIR/launchd.log</string>
    <key>StandardErrorPath</key><string>$APP_DIR/launchd.log</string>
</dict>
</plist>
PLIST_EOF
    # Swap the temporary process for the always-on one.
    pkill -f "$ST_HOME" 2>/dev/null
    sleep 2
    launchctl unload "$PLIST" 2>/dev/null
    launchctl load "$PLIST" || die "Could not switch sync on permanently."
    echo "  Done — sync now survives restarts."
fi

# ---------- 7. open the Claude Desktop extension ------------------------------
# From a zip, the extension sits next to this script. From a one-line curl
# invite there are no adjacent files, so we fetch it from --mcpb-url instead.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
MCPB="${SCRIPT_DIR:-}/AI-Vault.mcpb"
echo ""
if [ ! -f "$MCPB" ] && [ -n "$MCPB_URL" ]; then
    echo "Fetching the Claude extension..."
    MCPB_TMP="$(mktemp -d)/AI-Vault.mcpb"
    if curl -fsSL -m 120 -o "$MCPB_TMP" "$MCPB_URL"; then
        MCPB="$MCPB_TMP"
        xattr -d com.apple.quarantine "$MCPB" 2>/dev/null || true
    else
        echo "  Could not download the extension automatically — we can add it by hand at the end."
    fi
fi
if [ "$TEST_MODE" = "1" ]; then
    echo "TEST MODE: would now open $MCPB in Claude Desktop's install window."
else
    [ -f "$MCPB" ] || die "The AI-Vault extension file is missing from this download."
    open "$MCPB" || die "Could not open the AI-Vault extension. Is Claude Desktop installed?"
fi

echo ""
echo "============================================================"
echo "   NEARLY DONE — two clicks left, in the Claude window:"
echo ""
echo "   1. Click the Install button."
echo "   2. When it asks for your Vault folder, choose:"
echo "      $VAULT_DIR"
echo ""
echo "   Then ask Claude your first question, for example:"
echo "   \"What do you know about my business?\""
echo "============================================================"
echo ""
