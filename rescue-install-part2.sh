#!/bin/bash
# ==========================================================================
# rescue-install-part2.sh   —   Rescue Rangers, the easy way (PART 2)
# --------------------------------------------------------------------------
# Run this AFTER your agent has created the tunnel and given you a token.
# Installs the connector, hardens it (http2 + KeepAlive + RunAtLoad),
# drops your SSH key, and verifies the tunnel is up on HTTP/2.
#
# Python-free on purpose: uses PlistBuddy (built into every Mac) so a broken
# client Python can never stop the hardening. Auto-detects Track A vs B and
# protects the client's own tunnel.
#
# RUN IT (no sudo in front — it asks for the password itself):
#     bash rescue-install-part2.sh <TOKEN> <firstname-lastname>
# ==========================================================================
set -uo pipefail

ZHC_ACCOUNT="13f808b72eb78027a8046357c6cf1afa"
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4Bx1veA6T4y7SUA+qOsCM67ZKU45eggwcg0VPT/7tK stefanie@trevsmacmini"
PB=/usr/libexec/PlistBuddy
CFPLIST=/Library/LaunchDaemons/com.cloudflare.cloudflared.plist

TOKEN="${1:-}"
SLUG="${2:-}"
if [ -z "${TOKEN}" ]; then
  echo "FAIL: no token given."
  echo "Usage: bash rescue-install-part2.sh <TOKEN> <firstname-lastname>"
  exit 1
fi

echo "=================================================="
echo " Rescue Rangers install (Part 2) — connector + hardening"
echo "=================================================="
echo "This needs your Mac password once."
sudo -v || { echo "FAIL: could not get admin rights."; exit 1; }
echo

CFBIN="$(command -v cloudflared || echo /opt/homebrew/bin/cloudflared)"

# --- Decide the track (no Python) -----------------------------------------
TRACK="A"
if [ -f "${CFPLIST}" ]; then
  EXIST_TOKEN="$(sudo "${PB}" -c "Print :ProgramArguments" "${CFPLIST}" 2>/dev/null | grep -Eo 'eyJ[A-Za-z0-9+/=_-]+' | head -1)"
  EXIST_ACCT="$(printf '%s' "${EXIST_TOKEN}" | base64 -D 2>/dev/null | sed -n 's/.*"a":"\([a-f0-9]*\)".*/\1/p')"
  if [ "${EXIST_ACCT}" = "${ZHC_ACCOUNT}" ]; then
    TRACK="A"
  else
    TRACK="B"
  fi
fi
echo "  Detected TRACK ${TRACK}"
if [ "${TRACK}" = "B" ] && [ -z "${SLUG}" ]; then
  echo "FAIL: Track B needs the client slug, e.g. star-bobatoon, as the 2nd argument."
  exit 1
fi

# --- Install / write the connector ----------------------------------------
if [ "${TRACK}" = "A" ]; then
  echo "  ... installing connector (Track A) ..."
  sudo "${CFBIN}" service install "${TOKEN}"
  PLIST="${CFPLIST}"
  LABEL="com.cloudflare.cloudflared"
else
  echo "  ... writing side-by-side rescue connector (Track B) ..."
  LABEL="com.blackceo.rescue-${SLUG}"
  PLIST="/Library/LaunchDaemons/${LABEL}.plist"
  sudo tee "${PLIST}" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CFBIN}</string>
        <string>tunnel</string><string>--protocol</string><string>http2</string><string>run</string>
        <string>--token</string><string>${TOKEN}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/Library/Logs/${LABEL}.out.log</string>
    <key>StandardErrorPath</key><string>/Library/Logs/${LABEL}.err.log</string>
</dict>
</plist>
PLISTEOF
  sudo chown root:wheel "${PLIST}"
  sudo chmod 644 "${PLIST}"
fi

# --- Harden with PlistBuddy (no Python) -----------------------------------
if ! sudo "${PB}" -c "Print :ProgramArguments" "${PLIST}" 2>/dev/null | grep -q http2; then
  sudo "${PB}" -c "Add :ProgramArguments: string --protocol" "${PLIST}"
  sudo "${PB}" -c "Add :ProgramArguments: string http2" "${PLIST}"
fi
sudo "${PB}" -c "Delete :KeepAlive" "${PLIST}" 2>/dev/null
sudo "${PB}" -c "Add :KeepAlive bool true" "${PLIST}"
sudo "${PB}" -c "Delete :RunAtLoad" "${PLIST}" 2>/dev/null
sudo "${PB}" -c "Add :RunAtLoad bool true" "${PLIST}"
echo "  + hardened (http2, KeepAlive, RunAtLoad)"

# --- Reload: bootout + bootstrap (NOT kickstart) --------------------------
# After a fresh "service install" the daemon needs a moment to fully release
# before it can be reloaded, or bootstrap fails with "Input/output error"
# (already loaded). So: bootout, wait, bootstrap; if it still fails, bootout
# again, wait longer, and bootstrap once more.
echo "  ... reloading (bootout + bootstrap) ..."
sudo launchctl bootout "system/${LABEL}" 2>/dev/null
sleep 3
if ! sudo launchctl bootstrap system "${PLIST}" 2>/dev/null; then
  echo "  ... first bootstrap raced, waiting and retrying ..."
  sudo launchctl bootout "system/${LABEL}" 2>/dev/null
  sleep 4
  sudo launchctl bootstrap system "${PLIST}"
fi

# --- Drop your SSH key (as the real user) ---------------------------------
touch "$HOME/.ssh/authorized_keys"
if ! grep -qF "${SSH_KEY}" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
  echo "${SSH_KEY}" >> "$HOME/.ssh/authorized_keys"
fi
chmod 600 "$HOME/.ssh/authorized_keys"
echo "  + SSH key in place"

# --- Belt: never sleep ----------------------------------------------------
sudo pmset -a sleep 0 displaysleep 0 disablesleep 1 >/dev/null 2>&1

# --- Verify ---------------------------------------------------------------
echo
echo "  ... verifying (waiting 8s for connections) ..."
sleep 8
LOG="/Library/Logs/${LABEL}.err.log"
sudo grep -i "Registered tunnel connection" "${LOG}" 2>/dev/null | tail -4
if sudo grep -i "Registered tunnel connection" "${LOG}" 2>/dev/null | tail -4 | grep -q "protocol=http2"; then
  echo
  echo "PASS: connector is up on HTTP/2 and hardened. Track ${TRACK}."
else
  echo
  echo "CHECK: did not see protocol=http2 on the live connections yet. Wait 15s, then:"
  echo "    sudo grep -i 'Registered tunnel connection' ${LOG} | tail -4"
fi
echo
echo "Now finish on YOUR side: Access app + service token, ~/.ssh/config entry, fleet registration."
