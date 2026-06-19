# Rescue Rangers — Easy Way

Set up a client for remote SSH access in two pasted lines instead of 40 minutes of typing.

**Rule of thumb:** lines that go into the **client's Terminal** start with `curl`. Prompts that go to **your AI agent** are in the "Tell your agent" blocks. Both `curl` lines run on the **client's** Mac. The client never opens GitHub or downloads anything by hand — the `curl` does it.

---

## The whole call, in order

### Step 1 — Run Part 1 on the client's Mac
On Zoom, have the client open Terminal. Paste this one line, press Return, they type their Mac password once:

```
curl -fsSL https://raw.githubusercontent.com/trevorotts1/rescue-rangers/main/rescue-setup-part1.sh -o ~/p1.sh && bash ~/p1.sh
```

It installs everything (Homebrew, cloudflared, Node, OpenClaw), sets never-sleep, and prints a **SUMMARY** with **TRACK A or B** and the username. Copy that SUMMARY.

### Step 2 — Tell your agent to make the tunnel
Paste this to your AI agent, with the client's real name in place of `<firstname>-<lastname>`, and paste the SUMMARY underneath:

```
Create a Cloudflare tunnel in my ZHC account 13f808b72eb78027a8046357c6cf1afa named rescue-<firstname>-<lastname>, hostname rescue-<firstname>-<lastname>.zerohumanworkforce.com, ingress ssh://localhost:22. Create the DNS CNAME on zerohumanworkforce.com and verify the tunnel by ID. Then give me back ONE thing: the exact Part 2 command line, ready to paste on the client's Mac, with BOTH the token AND the client name filled in, in this form:
curl -fsSL https://raw.githubusercontent.com/trevorotts1/rescue-rangers/main/rescue-install-part2.sh -o ~/p2.sh && bash ~/p2.sh THE-TOKEN firstname-lastname
Nothing left for me to edit. Do not rotate or recreate the tunnel afterward.
```

The agent hands you a finished line with the token already inside it.

### Step 3 — Run Part 2 on the client's Mac
Copy the whole line your agent gave you, paste it into the client's Terminal, press Return. It installs the connector, hardens it (HTTP/2, KeepAlive, RunAtLoad), drops your SSH key, and verifies. Wait for **PASS**.

### Step 4 — Tell your agent to finish
Paste this to your agent:

```
Finish rescue-<firstname>-<lastname>: create the Access app and service token (180-day, Google SSO, my four emails), add the ~/.ssh/config entry, register the client in the fleet (all six files), then run the smoke test and report ssh=OK gw=OK.
```

Done.

---

## If Part 2 shows `quic` instead of `http2`
Run the Part 2 line again. If it still shows `quic`, do Step F0 of the full Field Install Guide by hand. The rule: to apply a plist change use `bootout` then `bootstrap`, **never** `kickstart`. (As of 2026-06-18, Part 2 does this automatically and retries once if the first `bootstrap` races.)

## Files in this repo
- `rescue-setup-part1.sh` — local prep + installs + track detection (runs on client's Mac)
- `rescue-install-part2.sh` — connector install + hardening (runs on client's Mac, takes the token). As of 2026-06-18 it **auto-retries** the launchd reload (`bootout`+`bootstrap`) if the first attempt hits the `Bootstrap failed: 5: Input/output error` race.

---

_Last updated: 2026-06-18 — Part 2 auto-retries the launchd reload to fix the bootstrap I/O race; see [CHANGELOG.md](CHANGELOG.md). Field guide: v20._
