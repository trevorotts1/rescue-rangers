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

# --- Decide the track -----------------------------------------------------
# Track B only if there is an existing cloudflared in a DIFFERENT account.
TRACK="A"
if sudo launchctl list 2>/dev/null | grep -q com.cloudflare.cloudflared \
   && [ -f /Library/LaunchDaemons/com.cloudflare.cloudflared.plist ]; then
  ACCT="$(sudo python3 -c 'import plistlib,base64,json
d=plistlib.load(open("/Library/LaunchDaemons/com.cloudflare.cloudflared.plist","rb"))
a=d.get("ProgramArguments",[]); t=a[a.index("--token")+1] if "--token" in a else ""
print(json.loads(base64.b64decode(t+"=="*(-len(t)%4)))["a"]) if t else print("none")' 2>/dev/null)"
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
if [ "${TRACK}" = "A" ]; then
  echo "  ... installing connector (Track A) ..."
  sudo "${CFBIN}" service install "${TOKEN}"
  PLIST="/Library/LaunchDaemons/com.cloudflare.cloudflared.plist"
  LABEL="com.cloudflare.cloudflared"
  # Harden deterministically: http2 + KeepAlive + RunAtLoad
  sudo python3 -c 'import plistlib,pathlib,sys
p=pathlib.Path("/Library/LaunchDaemons/com.cloudflare.cloudflared.plist")
d=plistlib.loads(p.read_bytes()); a=d["ProgramArguments"]; t=a[a.index("--token")+1]
d["ProgramArguments"]=[a[0],"tunnel","--protocol","http2","run","--token",t]
d["KeepAlive"]=True; d["RunAtLoad"]=True
p.write_bytes(plistlib.dumps(d,sort_keys=False)); print("  + hardened (http2, KeepAlive, RunAtLoad)")'
else
  echo "  ... writing side-by-side rescue connector (Track B) ..."
  LABEL="com.blackceo.rescue-${SLUG}"
  PLIST="/Library/LaunchDaemons/${LABEL}.plist"
  sudo python3 - "$CFBIN" "$TOKEN" "$LABEL" "$PLIST" <<'PY'
import plistlib, sys, pathlib
cfbin, token, label, plist = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = {
  "Label": label,
  "ProgramArguments": [cfbin, "tunnel", "--protocol", "http2", "run", "--token", token],
  "RunAtLoad": True,
  "KeepAlive": True,
  "StandardOutPath": f"/Library/Logs/{label}.out.log",
  "StandardErrorPath": f"/Library/Logs/{label}.err.log",
}
pathlib.Path(plist).write_bytes(plistlib.dumps(d, sort_keys=False))
print("  + wrote", plist)
PY
  sudo chown root:wheel "${PLIST}"
  sudo chmod 644 "${PLIST}"
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
