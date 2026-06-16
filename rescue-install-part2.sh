#!/bin/bash
# ==========================================================================
# rescue-install-part2.sh   —   Rescue Rangers, the easy way (PART 2)
# --------------------------------------------------------------------------
# Run this AFTER your agent has created the tunnel and given you a token.
# It installs the connector, hardens it (http2 + KeepAlive + RunAtLoad),
# drops your SSH key, and verifies the tunnel is up on HTTP/2.
#
# It auto-detects Track A vs Track B and protects the client's own tunnel.
#
# No Python required — uses /usr/libexec/PlistBuddy (built into macOS).
#
# RUN IT (no sudo in front — it asks for the password itself):
#     bash rescue-install-part2.sh <TOKEN> <firstname-lastname>
#
# Example:
#     bash rescue-install-part2.sh eyJhIjoiMTN...ifQ== erin-garrett
# ==========================================================================
set -uo pipefail

ZHC_ACCOUNT="13f808b72eb78027a8046357c6cf1afa"
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4Bx1veA6T4y7SUA+qOsCM67ZKU45eggwcg0VPT/7tK stefanie@trevsmacmini"

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

# --- Helper: decode a JWT token payload to extract the "a" (account) field
_decode_jwt_account() {
  local t="${1:-}"
  [ -z "$t" ] && return 1
  local payload="${t#*.}"; payload="${payload%.*}"
  local rem=$(( ${#payload} % 4 )) pad=0
  [ "$rem" -ne 0 ] && pad=$(( 4 - rem ))
  while [ "$pad" -gt 0 ]; do payload="${payload}="; pad=$((pad-1)); done
  echo "$payload" | base64 -d 2>/dev/null | sed -n 's/.*"a" *: *"\([^"]*\)".*/\1/p'
}

# --- Decide the track -----------------------------------------------------
# Track B only if there is an existing cloudflared in a DIFFERENT account.
TRACK="A"
if sudo launchctl list 2>/dev/null | grep -q com.cloudflare.cloudflared \
   && [ -f /Library/LaunchDaemons/com.cloudflare.cloudflared.plist ]; then
  ACCT=""
  ARGS="$(sudo /usr/libexec/PlistBuddy -c "Print :ProgramArguments" /Library/LaunchDaemons/com.cloudflare.cloudflared.plist 2>/dev/null || true)"
  if [ -n "$ARGS" ]; then
    CT=$(echo "$ARGS" | awk '/--token/{getline; gsub(/^[ \t]+/,""); print}')
    CT="${CT%"${CT##*[![:space:]]}"}"
    [ -n "$CT" ] && ACCT="$(_decode_jwt_account "$CT")"
  fi
  if [ -n "${ACCT}" ] && [ "${ACCT}" != "none" ] && [ "${ACCT}" != "${ZHC_ACCOUNT}" ]; then
    TRACK="B"
  fi
fi
echo "  Detected TRACK ${TRACK}"
if [ "${TRACK}" = "B" ] && [ -z "${SLUG}" ]; then
  echo "FAIL: Track B needs the client slug, e.g. erin-garrett, as the 2nd argument."
  exit 1
fi

# --- Install / write the connector ----------------------------------------
PB="/usr/libexec/PlistBuddy"

if [ "${TRACK}" = "A" ]; then
  echo "  ... installing connector (Track A) ..."
  sudo "${CFBIN}" service install "${TOKEN}"
  PLIST="/Library/LaunchDaemons/com.cloudflare.cloudflared.plist"
  LABEL="com.cloudflare.cloudflared"

  # Harden deterministically with PlistBuddy (no Python needed)
  echo "  ... hardening (http2 + KeepAlive + RunAtLoad) ..."
  # Build new ProgramArguments: cloudflared tunnel --protocol http2 run --token <token>
  sudo ${PB} -c "Delete :ProgramArguments" "${PLIST}" 2>/dev/null
  sudo ${PB} -c "Add :ProgramArguments array" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:0 string ${CFBIN}" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:1 string tunnel" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:2 string --protocol" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:3 string http2" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:4 string run" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:5 string --token" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:6 string ${TOKEN}" "${PLIST}"
  # Add KeepAlive (may already exist from service install)
  sudo ${PB} -c "Add :KeepAlive bool true" "${PLIST}" 2>/dev/null || \
    sudo ${PB} -c "Set :KeepAlive true" "${PLIST}"
  # Ensure RunAtLoad
  sudo ${PB} -c "Add :RunAtLoad bool true" "${PLIST}" 2>/dev/null || \
    sudo ${PB} -c "Set :RunAtLoad true" "${PLIST}"
  echo "  + hardened (http2, KeepAlive, RunAtLoad)"
else
  echo "  ... writing side-by-side rescue connector (Track B) ..."
  LABEL="com.blackceo.rescue-${SLUG}"
  PLIST="/Library/LaunchDaemons/${LABEL}.plist"

  # Create a fresh plist with PlistBuddy
  # First write a minimal valid XML skeleton
  cat <<XMLEND | sudo tee "${PLIST}" >/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
XMLEND

  sudo ${PB} -c "Add :Label string ${LABEL}" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments array" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:0 string ${CFBIN}" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:1 string tunnel" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:2 string --protocol" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:3 string http2" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:4 string run" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:5 string --token" "${PLIST}"
  sudo ${PB} -c "Add :ProgramArguments:6 string ${TOKEN}" "${PLIST}"
  sudo ${PB} -c "Add :RunAtLoad bool true" "${PLIST}"
  sudo ${PB} -c "Add :KeepAlive bool true" "${PLIST}"
  sudo ${PB} -c "Add :StandardOutPath string /Library/Logs/${LABEL}.out.log" "${PLIST}"
  sudo ${PB} -c "Add :StandardErrorPath string /Library/Logs/${LABEL}.err.log" "${PLIST}"
  sudo chown root:wheel "${PLIST}"
  sudo chmod 644 "${PLIST}"
  echo "  + wrote ${PLIST}"
fi

# --- Reload the RIGHT way: bootout + bootstrap (NOT kickstart) -------------
echo "  ... reloading (bootout + bootstrap) ..."
sudo launchctl bootout "system/${LABEL}" 2>/dev/null
sudo launchctl bootstrap system "${PLIST}"

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
sudo grep -i protocol "${LOG}" 2>/dev/null | tail -4
if sudo grep -iq "protocol=http2" "${LOG}" 2>/dev/null; then
  echo
  echo "PASS: connector is up on HTTP/2 and hardened. Track ${TRACK}."
else
  echo
  echo "CHECK: did not see protocol=http2 yet. Wait 15s, then:"
  echo "    sudo grep -i protocol ${LOG} | tail -4"
fi
echo
echo "Now finish on YOUR side: create the Access app + service token,"
echo "add the ~/.ssh/config entry, and register the client in the fleet."
