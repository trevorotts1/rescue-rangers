#!/bin/bash
# ==========================================================================
# rescue-setup-part1.sh — Rescue Rangers, the easy way (PART 1)
# --------------------------------------------------------------------------
# Run this on the CLIENT'S Mac at the start of the call. It does ALL the
# local prep in one shot, then tells you Track A or Track B.
#
# It does NOT touch your Cloudflare account. Creating the tunnel is your
# agent's job (that needs your API key, which never belongs on a client Mac).
#
# RUN IT (do NOT put sudo in front — the script asks for the password itself):
# bash rescue-setup-part1.sh
# ==========================================================================
set -uo pipefail

ZHC_ACCOUNT="13f808b72eb78027a8046357c6cf1afa" # your account id
CFPLIST="/Library/LaunchDaemons/com.cloudflare.cloudflared.plist"

echo "=================================================="
echo " Rescue Rangers setup (Part 1) — local prep"
echo "=================================================="
echo "This needs your Mac password once. Enter it when asked."
sudo -v || { echo "FAIL: could not get admin rights."; exit 1; }
echo

# --- 1) SSH folder (as the real user) -------------------------------------
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
echo " + ~/.ssh ready"

# --- 2) FileVault status (report only) ------------------------------------
FV="$(fdesetup status 2>/dev/null)"
echo " i ${FV}"
if echo "${FV}" | grep -qi "On"; then
 echo " ! FileVault is ON. For a rescue box you want it OFF so the tunnel"
 echo " comes back by itself after a restart. Turn it off in"
 echo " System Settings > Privacy & Security > FileVault."
fi

# --- 3) Remote Login (SSH server) ON --------------------------------------
sudo systemsetup -setremotelogin on >/dev/null 2>&1
RL="$(sudo systemsetup -getremotelogin 2>/dev/null)"
echo " + ${RL}"

# --- 4) Never sleep + survive lid close -----------------------------------
sudo pmset -a sleep 0 displaysleep 0 disablesleep 1 >/dev/null 2>&1
echo " + sleep disabled (sleep 0, disablesleep 1)"

# --- 5) Homebrew (install if missing, and fix the PATH) --------------------
if [ -x /opt/homebrew/bin/brew ]; then
 BREW=/opt/homebrew/bin/brew # Apple Silicon
elif [ -x /usr/local/bin/brew ]; then
 BREW=/usr/local/bin/brew # Intel
else
 BREW=""
fi

if [ -z "${BREW}" ]; then
 echo " ... Homebrew not found. Installing (this takes a few minutes) ..."
 NONINTERACTIVE=1 /bin/bash -c \
 "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
 if [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew; else BREW=/usr/local/bin/brew; fi
 # Teach this shell AND future shells where brew lives
 eval "$("${BREW}" shellenv)"
 if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
 echo "" >> "$HOME/.zprofile"
 echo "eval \"\$(${BREW} shellenv)\"" >> "$HOME/.zprofile"
 fi
 echo " + Homebrew installed and PATH fixed"
else
 eval "$("${BREW}" shellenv)"
 echo " = Homebrew already installed"
fi

# --- 6) cloudflared (skip if present) -------------------------------------
if command -v cloudflared >/dev/null 2>&1; then
 echo " = cloudflared already installed ($(cloudflared --version 2>/dev/null | head -1))"
else
 echo " ... installing cloudflared ..."
 "${BREW}" install cloudflared && echo " + cloudflared installed"
fi

# --- 7) Node.js (skip if present) -----------------------------------------
if command -v node >/dev/null 2>&1; then
 echo " = Node.js already installed ($(node --version 2>/dev/null))"
else
 echo " ... installing Node.js ..."
 "${BREW}" install node && echo " + Node.js installed"
fi

# --- 8) OpenClaw (skip if present) ----------------------------------------
# NOTE: this assumes OpenClaw installs as a global npm package. If your
# install method is different, change the install line below to match.
if command -v openclaw >/dev/null 2>&1; then
 echo " = OpenClaw already installed ($(openclaw --version 2>/dev/null | head -1))"
else
 echo " ... installing OpenClaw (npm global) ..."
 npm install -g openclaw >/dev/null 2>&1 \
 && echo " + OpenClaw installed" \
 || echo " ! OpenClaw install did not complete — install it manually if needed"
fi

# --- 9) Track detection ---------------------------------------------------
echo
echo "----- TRACK DETECTION -----"
if [ -f "${CFPLIST}" ]; then
 TKN="$(sudo /usr/libexec/PlistBuddy -c "Print :ProgramArguments" "${CFPLIST}" 2>/dev/null | grep -Eo 'eyJ[A-Za-z0-9+/=_-]+' | head -1)"
 ACCT="$(printf '%s' "${TKN}" | base64 -D 2>/dev/null | sed -n 's/.*"a":"\([a-f0-9]*\)".*/\1/p')"
 if [ "${ACCT}" = "${ZHC_ACCOUNT}" ]; then
 echo " TRACK A (re-run): a cloudflared in YOUR account is already here."
 elif [ -n "${ACCT}" ]; then
 echo " TRACK B: the client already has their OWN cloudflared (account ${ACCT})."
 echo " Part 2 will add our rescue tunnel side-by-side and NOT touch theirs."
 else
 echo " TRACK B: a cloudflared service exists but its account could not be read."
 echo " Treating as Track B so Part 2 does NOT clobber the client's tunnel."
 fi
else
 echo " TRACK A: no existing cloudflared. Clean single-tunnel install."
fi

# --- 10) Summary ----------------------------------------------------------
echo
echo "=================================================="
echo " SUMMARY"
echo " User: $(whoami)"
echo " Mac name: $(scutil --get LocalHostName 2>/dev/null)"
echo " ${FV}"
echo " ${RL}"
echo " cloudflared: $(command -v cloudflared >/dev/null 2>&1 && cloudflared --version 2>/dev/null | head -1 || echo missing)"
echo " node: $(command -v node >/dev/null 2>&1 && node --version || echo missing)"
echo " openclaw: $(command -v openclaw >/dev/null 2>&1 && openclaw --version 2>/dev/null | head -1 || echo missing)"
echo "=================================================="
echo "Part 1 done. Send the SUMMARY + TRACK to your agent so it can"
echo "create the tunnel and give you the token for Part 2."