#!/bin/bash
# ==========================================================================
# rescue-install.sh   v3.0   Rescue Rangers install (Mac only, ONE script)
# --------------------------------------------------------------------------
# Replaces rescue-setup-part1.sh and rescue-install-part2.sh.
#
# Your agent creates the tunnel BEFORE the call and hands you this line
# with the token already in it. The client runs it once:
#
#     curl -fsSL https://raw.githubusercontent.com/trevorotts1/rescue-rangers/main/rescue-install.sh -o ~/rr.sh && bash ~/rr.sh <TOKEN> <firstname-lastname>
#
# Order (fails fast, before anything slow):
#   1. Check the token is a genuine ZHC rescue token.
#   2. Re-assert Remote Login / no-sleep / autorestart, then check FileVault
#      and Automatic Login. If those are wrong it STOPS in seconds.
#   3. Homebrew, cloudflared, Node, and the LATEST STABLE OpenClaw
#      (npm dist-tag "latest" only; never beta, never another channel).
#   4. Read-only inventory of any Cloudflare tunnel already on the Mac.
#   5. Our connector as com.blackceo.rescue-<slug> (every Mac, Track A or B),
#      hardened, loaded, SSH key dropped. Never touches a client tunnel.
#   6. Layer E watchdog installed and pinned to our label.
#   7. Waits up to 45s for live HTTP/2 connections, prints one SUMMARY.
#
# Safe to re-run with the same line after fixing anything it reports.
# VPS and Contabo boxes do NOT use this script.
# ==========================================================================
set -uo pipefail

ZHC_ACCOUNT="13f808b72eb78027a8046357c6cf1afa"
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4Bx1veA6T4y7SUA+qOsCM67ZKU45eggwcg0VPT/7tK stefanie@trevsmacmini"
PB=/usr/libexec/PlistBuddy
CFPLIST=/Library/LaunchDaemons/com.cloudflare.cloudflared.plist
WD_LABEL="com.blackceo.rescue-tunnel-watchdog"
WD_PLIST="/Library/LaunchDaemons/${WD_LABEL}.plist"
WD_RAW="https://raw.githubusercontent.com/trevorotts1/openclaw-onboarding/main/platform/mac/tunnel-hardening"
NODE_MIN="22.22.3"
WARNINGS=""
warn() { WARNINGS="${WARNINGS}\n   - $1"; echo "  !  $1"; }

TOKEN="${1:-}"
SLUG="${2:-}"

# --- helpers --------------------------------------------------------------
ver_ge() {
  local IFS=.
  local va=($1) vb=($2) i x y
  for i in 0 1 2; do
    x="${va[$i]:-0}"; y="${vb[$i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x="${x:-0}"; y="${y:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 0
}
token_field() {
  local t="$1" k="$2" m
  m=$(( ${#t} % 4 ))
  if [ "$m" -ne 0 ]; then t="${t}$(printf '%*s' $((4 - m)) '' | tr ' ' '=')"; fi
  printf '%s' "$t" | base64 -D 2>/dev/null | sed -n "s/.*\"${k}\":\"\\([^\"]*\\)\".*/\\1/p"
}
is_prerelease() { echo "$1" | grep -Eqi 'beta|alpha|rc|dev|canary|next|nightly|preview'; }
plist_token() { sudo "$PB" -c "Print :ProgramArguments" "$1" 2>/dev/null | grep -Eo 'eyJ[A-Za-z0-9+/=_-]+' | head -1; }

echo "=================================================="
echo " Rescue Rangers install v3.0"
echo "=================================================="

# === 1) Arguments and token (no changes made yet) ==========================
if [ "$(uname -s)" != "Darwin" ]; then
  echo "FAIL: Macs only. VPS and Contabo boxes use the VPS path in the walkthrough."; exit 1
fi
if [ -z "$TOKEN" ] || [ -z "$SLUG" ]; then
  echo "FAIL: missing arguments. Usage: bash rescue-install.sh <TOKEN> <firstname-lastname>"; exit 1
fi
if ! echo "$SLUG" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)+$'; then
  echo "FAIL: slug '${SLUG}' must look like firstname-lastname (lowercase, hyphens)."; exit 1
fi
NEW_A="$(token_field "$TOKEN" a)"; NEW_T="$(token_field "$TOKEN" t)"; NEW_S="$(token_field "$TOKEN" s)"
if [ "$NEW_A" != "$ZHC_ACCOUNT" ] || [ -z "$NEW_T" ] || [ -z "$NEW_S" ]; then
  echo "FAIL: this is not a valid ZHC rescue token (account=${NEW_A:-unreadable})."
  echo "Ask your agent for the GENUINE token pulled from the Cloudflare API."; exit 1
fi
echo "  + token belongs to ZHC, tunnel ${NEW_T}"
LABEL="com.blackceo.rescue-${SLUG}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG_ERR="/Library/Logs/${LABEL}.err.log"

echo "This needs your Mac password once. Enter it when asked."
sudo -v || { echo "FAIL: could not get admin rights."; exit 1; }
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPER=$!
trap 'kill "$SUDO_KEEPER" 2>/dev/null' EXIT
echo

# === 2) Settings: re-assert, then check (stops fast if wrong) ==============
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
sudo systemsetup -setremotelogin on >/dev/null 2>&1
sudo pmset -a sleep 0 displaysleep 0 disablesleep 1 >/dev/null 2>&1
sudo pmset -a autorestart 1 >/dev/null 2>&1
echo "  + Remote Login on, sleep off, restart-after-power-failure on"

STOP=""
FV="$(fdesetup status 2>/dev/null | head -1)"
echo "$FV" | grep -qi "FileVault is On" && STOP="${STOP}\n   - FileVault is ON. Turn it OFF in System Settings > Privacy & Security > FileVault."
RL="$(sudo systemsetup -getremotelogin 2>/dev/null)"
echo "$RL" | grep -qi ": On" || STOP="${STOP}\n   - Remote Login is not On."
ME="$(whoami)"
ALU="$(sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
if [ "$ALU" = "$ME" ] && sudo test -f /etc/kcpassword; then
  AUTOLOGIN="On for ${ME} (kcpassword present)"
else
  AUTOLOGIN="NOT SET"
  STOP="${STOP}\n   - Automatic Login is not set. System Settings > Users & Groups > Automatic login as ${ME}."
fi
if [ -n "$STOP" ]; then
  echo
  echo "STOPPED: fix these in System Settings, then run the SAME line again:"
  printf "%b\n" "$STOP"
  exit 2
fi
echo "  + FileVault off, Remote Login on, Automatic Login on"
if sudo head -c 1 "/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; then
  FDA="granted"
else
  FDA="NOT granted (likely)"
  warn "Full Disk Access for Terminal looks missing. Grant it, quit and reopen Terminal (the install continues)."
fi

# === 3) Software ===========================================================
if [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then BREW=/usr/local/bin/brew
else BREW=""; fi
if [ -z "$BREW" ]; then
  echo "  ... Homebrew not found. Installing (a few minutes) ..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew; else BREW=/usr/local/bin/brew; fi
  eval "$("$BREW" shellenv)"
  grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || printf '\neval "$(%s shellenv)"\n' "$BREW" >> "$HOME/.zprofile"
  echo "  + Homebrew installed and PATH fixed"
else
  eval "$("$BREW" shellenv)"
  echo "  = Homebrew already installed"
fi
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1

if command -v cloudflared >/dev/null 2>&1; then
  echo "  = cloudflared $(cloudflared --version 2>/dev/null | head -1 | awk '{print $3}')"
else
  echo "  ... installing cloudflared ..."
  "$BREW" install cloudflared >/dev/null 2>&1 || { echo "FAIL: cloudflared did not install."; exit 1; }
  echo "  + cloudflared installed"
fi
CFBIN="$(command -v cloudflared)"

if command -v node >/dev/null 2>&1; then
  NV="$(node --version 2>/dev/null | sed 's/^v//')"
  if ver_ge "$NV" "$NODE_MIN"; then echo "  = Node.js ${NV}"
  elif "$BREW" list node >/dev/null 2>&1; then
    echo "  ... Node.js ${NV} too old, upgrading ..."
    "$BREW" upgrade node >/dev/null 2>&1 || warn "Node.js upgrade failed."
  else warn "Node.js ${NV} is older than ${NODE_MIN} and not from Homebrew. OpenClaw may not install."
  fi
else
  echo "  ... installing Node.js ..."
  "$BREW" install node >/dev/null 2>&1 || warn "Node.js did not install."
fi
hash -r 2>/dev/null

LATEST="$(npm view openclaw dist-tags.latest 2>/dev/null | tr -d '[:space:]')"
OC_STATUS="unknown"
if [ -z "$LATEST" ]; then
  warn "Could not read the latest stable OpenClaw version from npm."
elif is_prerelease "$LATEST"; then
  warn "npm 'latest' returned a pre-release (${LATEST}). NOT installing. Tell the operator."
else
  NPM_FLAGS=""
  ver_ge "$(npm -v 2>/dev/null)" "11.16.0" && NPM_FLAGS="--allow-scripts=openclaw"
  INSTALLED=""
  command -v openclaw >/dev/null 2>&1 && INSTALLED="$(openclaw --version 2>/dev/null | head -1 | awk '{print $2}')"
  DO_INSTALL="no"
  if [ -z "$INSTALLED" ]; then DO_INSTALL="yes"
  elif [ "$INSTALLED" = "$LATEST" ]; then echo "  = OpenClaw ${INSTALLED} (latest stable)"
  elif [ ! -f "$HOME/.openclaw/openclaw.json" ]; then DO_INSTALL="yes"
  else
    OC_STATUS="BEHIND"
    warn "OpenClaw ${INSTALLED} is behind latest stable ${LATEST} on an onboarded box. Upgrade later with the fleet atomic upgrade."
  fi
  if [ "$DO_INSTALL" = "yes" ]; then
    echo "  ... installing OpenClaw ${LATEST} (latest stable) ..."
    if npm install -g "openclaw@${LATEST}" ${NPM_FLAGS} >/tmp/rr-openclaw-install.log 2>&1; then
      hash -r 2>/dev/null; echo "  + OpenClaw installed"
    else
      tail -6 /tmp/rr-openclaw-install.log | sed 's/^/     /'
      warn "OpenClaw install failed (lines above). The tunnel install continues."
    fi
  fi
  if [ "$OC_STATUS" != "BEHIND" ]; then
    NOW="$(command -v openclaw >/dev/null 2>&1 && openclaw --version 2>/dev/null | head -1 | awk '{print $2}')"
    if [ "$NOW" = "$LATEST" ]; then OC_STATUS="OK (latest stable)"; else OC_STATUS="MISMATCH (${NOW:-missing})"; fi
  fi
  [ "$(which -a openclaw 2>/dev/null | sort -u | wc -l | tr -d ' ')" -gt 1 ] && warn "More than one openclaw binary on the PATH. Remove the extra before onboarding."
fi

# === 4) Existing tunnel inventory (read-only) ==============================
echo
echo "----- EXISTING CLOUDFLARE ON THIS MAC (read-only) -----"
TRACK="A"
for p in /Library/LaunchDaemons/com.blackceo.rescue-*.plist; do
  [ -f "$p" ] || continue
  b="$(basename "$p" .plist)"
  [ "$b" = "$WD_LABEL" ] && continue
  [ "$b" = "$LABEL" ] && { echo "  OURS: ${b} already here (re-run)"; continue; }
  if [ "$(token_field "$(plist_token "$p")" t)" = "$NEW_T" ]; then
    echo "  ... same tunnel under an old label ${b}, removing it ..."
    sudo launchctl bootout "system/${b}" 2>/dev/null; sudo rm -f "$p"
  else
    echo "FAIL: another rescue connector (${b}) for a DIFFERENT tunnel is here. Stop and tell your agent."
    exit 1
  fi
done
if [ -f "$CFPLIST" ]; then
  OT="$(plist_token "$CFPLIST")"; OA="$(token_field "$OT" a)"; OTID="$(token_field "$OT" t)"
  if [ "$OA" = "$ZHC_ACCOUNT" ] && [ "$OTID" = "$NEW_T" ]; then
    echo "  ... old-style install of THIS tunnel on com.cloudflare.cloudflared, migrating ..."
    sudo launchctl bootout system/com.cloudflare.cloudflared 2>/dev/null
    sudo "$CFBIN" service uninstall >/dev/null 2>&1; sudo rm -f "$CFPLIST"
    echo "  + migrated"
  elif [ "$OA" = "$ZHC_ACCOUNT" ]; then
    warn "com.cloudflare.cloudflared runs a DIFFERENT tunnel from our account (${OTID}). Left alone. Tell your agent."
  else
    TRACK="B"; echo "  CLIENT-OWNED: LaunchDaemon com.cloudflare.cloudflared (account ${OA:-unreadable}). Not touching it."
  fi
fi
for d in /Library/LaunchDaemons /Library/LaunchAgents "$HOME/Library/LaunchAgents"; do
  for p in "$d"/*.plist; do
    [ -f "$p" ] || continue
    b="$(basename "$p" .plist)"
    case "$b" in com.blackceo.rescue-*|com.cloudflare.cloudflared|com.clawd.tunnel-*|com.zhc.tunnel-*) continue;; esac
    if sudo grep -q cloudflared "$p" 2>/dev/null; then TRACK="B"; echo "  CLIENT-OWNED: ${d}/${b}. Not touching it."; fi
  done
done
[ -f "$HOME/.cloudflared/config.yml" ] && { TRACK="B"; echo "  CLIENT-OWNED: ~/.cloudflared/config.yml. Not touching it."; }
[ "$TRACK" = "A" ] && echo "  None found."
echo "  TRACK ${TRACK}"

# === 5) Our connector ======================================================
echo
sudo launchctl bootout "system/${LABEL}" 2>/dev/null
sudo tee "$PLIST" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CFBIN}</string>
        <string>tunnel</string>
        <string>--protocol</string><string>http2</string>
        <string>run</string>
        <string>--token</string><string>${TOKEN}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>/Library/Logs/${LABEL}.out.log</string>
    <key>StandardErrorPath</key><string>${LOG_ERR}</string>
</dict>
</plist>
PLISTEOF
sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null 2>&1 || { echo "FAIL: connector plist did not validate."; exit 1; }
sudo launchctl enable "system/${LABEL}" 2>/dev/null
sleep 2
if ! sudo launchctl bootstrap system "$PLIST" 2>/dev/null; then
  echo "  ... first bootstrap raced, retrying ..."
  sudo launchctl bootout "system/${LABEL}" 2>/dev/null; sleep 4
  sudo launchctl bootstrap system "$PLIST" || { echo "FAIL: could not load ${LABEL}."; exit 1; }
fi
echo "  + connector ${LABEL} loaded (http2, KeepAlive, RunAtLoad)"

touch "$HOME/.ssh/authorized_keys"
grep -qF "$SSH_KEY" "$HOME/.ssh/authorized_keys" 2>/dev/null || echo "$SSH_KEY" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
echo "  + SSH key in place"

# === 6) Layer E watchdog, pinned to our label ==============================
WD_TMP="$(mktemp -d)"; WD_OK="no"
if curl -fsSL "${WD_RAW}/install-rescue-tunnel-watchdog.sh" -o "${WD_TMP}/install-rescue-tunnel-watchdog.sh" \
   && curl -fsSL "${WD_RAW}/rescue-tunnel-watchdog.sh" -o "${WD_TMP}/rescue-tunnel-watchdog.sh" \
   && curl -fsSL "${WD_RAW}/${WD_LABEL}.plist.template" -o "${WD_TMP}/${WD_LABEL}.plist.template"; then
  if sudo bash "${WD_TMP}/install-rescue-tunnel-watchdog.sh" >/tmp/rr-watchdog-install.log 2>&1; then
    sudo "$PB" -c "Delete :EnvironmentVariables" "$WD_PLIST" 2>/dev/null
    sudo "$PB" -c "Add :EnvironmentVariables dict" "$WD_PLIST"
    sudo "$PB" -c "Add :EnvironmentVariables:RESCUE_LABEL string ${LABEL}" "$WD_PLIST"
    sudo launchctl bootout "system/${WD_LABEL}" 2>/dev/null; sleep 2
    sudo launchctl bootstrap system "$WD_PLIST" 2>/dev/null
    sudo launchctl print "system/${WD_LABEL}" >/dev/null 2>&1 && WD_OK="yes"
  fi
fi
rm -rf "$WD_TMP"
if [ "$WD_OK" = "yes" ]; then echo "  + Layer E watchdog installed, pinned to ${LABEL}"
else warn "Layer E watchdog not confirmed (log /tmp/rr-watchdog-install.log). The connector still works; your agent can install it over SSH."; fi

# === 7) Verify: up to 45s ==================================================
echo
echo "  ... verifying (up to 45s) ..."
RESULT="CHECK"; RECENT=""
for _ in $(seq 1 15); do
  sleep 3
  RECENT="$(sudo tail -60 "$LOG_ERR" 2>/dev/null)"
  if echo "$RECENT" | grep -qi "Invalid tunnel secret"; then RESULT="BADTOKEN"; break; fi
  [ "$(echo "$RECENT" | grep -c "Registered tunnel connection.*protocol=http2")" -ge 2 ] && { RESULT="PASS"; break; }
done
echo "$RECENT" | grep -i "Registered tunnel connection" | tail -4

echo
echo "=================================================="
echo " SUMMARY  (rescue-install v3.0)   send this to your agent"
echo "   RESULT:          ${RESULT}"
echo "   Connector label: ${LABEL}"
echo "   Tunnel id:       ${NEW_T}"
echo "   TRACK:           ${TRACK}"
echo "   Watchdog:        ${WD_OK}"
echo "   User:            ${ME}"
echo "   Mac name:        $(scutil --get LocalHostName 2>/dev/null)"
echo "   Model / chip:    $(sysctl -n hw.model 2>/dev/null) / $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
echo "   macOS:           $(sw_vers -productVersion 2>/dev/null)"
echo "   ${FV}"
echo "   ${RL}"
echo "   Automatic login: ${AUTOLOGIN}"
echo "   Full Disk Access (Terminal): ${FDA}"
echo "   cloudflared:     $("$CFBIN" --version 2>/dev/null | head -1)"
echo "   node / npm:      $(node --version 2>/dev/null || echo missing) / $(npm -v 2>/dev/null || echo missing)"
echo "   openclaw:        $(command -v openclaw >/dev/null 2>&1 && openclaw --version 2>/dev/null | head -1 || echo missing)"
echo "   latest stable:   ${LATEST:-unknown}   status: ${OC_STATUS}"
if [ -n "$WARNINGS" ]; then echo "   WARNINGS:"; printf "%b\n" "$WARNINGS"; fi
case "$RESULT" in
  PASS)     echo "   >>> PASS: connector up on HTTP/2 and hardened." ;;
  BADTOKEN) echo "   >>> FAIL: BAD TOKEN ('Invalid tunnel secret'). Get a fresh GENUINE token and run again." ;;
  *)        echo "   >>> CHECK: no HTTP/2 connections yet. Last lines:"; sudo tail -6 "$LOG_ERR" 2>/dev/null | sed 's/^/       /' ;;
esac
echo "=================================================="
