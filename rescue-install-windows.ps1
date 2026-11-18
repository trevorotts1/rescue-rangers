# ==========================================================================
# rescue-install-windows.ps1   v1.0   Rescue Rangers install (Windows 10/11)
# --------------------------------------------------------------------------
# The Windows twin of rescue-install.sh (Mac). The client runs it ONCE, in
# PowerShell opened with "Run as administrator":
#
#   powershell -ExecutionPolicy Bypass -Command "iwr -useb https://raw.githubusercontent.com/trevorotts1/rescue-rangers/main/rescue-install-windows.ps1 -OutFile $env:TEMP\rr.ps1; & $env:TEMP\rr.ps1 -Token '<TOKEN>' -Slug '<firstname-lastname>'"
#
# Order (fails fast, before anything slow):
#   1. Check admin rights and that the token is a genuine ZHC rescue token.
#   2. Turn on OpenSSH Server (built into Windows), set it to start on boot,
#      make PowerShell the SSH shell, allow port 22 on the local machine only
#      (the tunnel reaches it on localhost; nothing is opened to the internet).
#   3. Put the operator SSH key in administrators_authorized_keys with the
#      exact permissions Windows OpenSSH requires.
#   4. Install cloudflared (official Cloudflare MSI, checksum logged).
#   5. Our connector as the Windows service "Cloudflared": token kept in a
#      locked file (--token-file), never on the command line; auto-start;
#      restart on failure. A client's own Cloudflare is never touched.
#   6. Sleep settings: never sleep on AC power (so the box stays reachable).
#   7. Wait up to 45s for live tunnel connections, print one SUMMARY.
#
# Safe to re-run with the same line after fixing anything it reports.
# ==========================================================================
param(
  [Parameter(Mandatory = $true)][string]$Token,
  [Parameter(Mandatory = $true)][string]$Slug
)
$ErrorActionPreference = 'Stop'
$ZHC_ACCOUNT = '13f808b72eb78027a8046357c6cf1afa'
$SSH_KEY     = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4Bx1veA6T4y7SUA+qOsCM67ZKU45eggwcg0VPT/7tK stefanie@trevsmacmini'
$CF_MSI_URL  = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi'
$CF_DIR      = Join-Path $env:ProgramData 'BlackCEO\rescue'
$TOKEN_FILE  = Join-Path $CF_DIR 'tunnel.token'
$LOG_FILE    = Join-Path $CF_DIR 'cloudflared.log'
$SVC         = 'Cloudflared'
$Warnings    = New-Object System.Collections.Generic.List[string]
function Warn($m) { $Warnings.Add($m); Write-Host "  !  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

Write-Host '=================================================='
Write-Host ' Rescue Rangers install (Windows) v1.0'
Write-Host '=================================================='

# === 1) Admin, arguments, token (no changes made yet) ======================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'open PowerShell with "Run as administrator" and paste the line again.' }
if ($Slug -notmatch '^[a-z0-9]+(-[a-z0-9]+)+$') { Fail "slug '$Slug' must look like firstname-lastname (lowercase, hyphens)." }
try {
  $b64 = $Token.Replace('-', '+').Replace('_', '/'); while ($b64.Length % 4) { $b64 += '=' }
  $tok = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
} catch { Fail 'this is not a valid ZHC rescue token (could not decode it). Ask your agent for the GENUINE token.' }
if ($tok.a -ne $ZHC_ACCOUNT -or -not $tok.t -or -not $tok.s) { Fail "this is not a valid ZHC rescue token (account=$($tok.a))." }
Write-Host "  + token belongs to ZHC, tunnel $($tok.t)"
$os = Get-CimInstance Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 17763) { Fail "Windows build $($os.BuildNumber) is too old for built-in OpenSSH (needs Windows 10 1809 or newer)." }

# === 2) OpenSSH Server ======================================================
Write-Host ''
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -ne 'Installed') {
  Write-Host '  ... installing OpenSSH Server (Windows feature, can take a few minutes) ...'
  Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-Host '  + OpenSSH Server installed, running, starts on boot'
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null
Write-Host '  + SSH sessions open in PowerShell'
# Port 22 is reached by the tunnel on localhost only. Keep any inbound rule local-only.
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Set-NetFirewallRule -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue
Write-Host '  + firewall: SSH not opened to the internet (tunnel only)'

# === 3) Operator SSH key ====================================================
$ak = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
if (-not (Test-Path $ak)) { New-Item -ItemType File -Path $ak -Force | Out-Null }
if (-not (Select-String -Path $ak -SimpleMatch $SSH_KEY -Quiet)) { Add-Content -Path $ak -Value $SSH_KEY -Encoding ascii }
icacls.exe $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
Write-Host '  + SSH key in place (administrators_authorized_keys, locked to Administrators + SYSTEM)'
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if (-not ((Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue).Name -contains $me)) { Warn "$me is not in the local Administrators group; the key above will not apply to this user." }

# === 4) cloudflared =========================================================
$cfExe = @("$env:ProgramFiles\cloudflared\cloudflared.exe", "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cfExe) {
  Write-Host '  ... installing cloudflared (official Cloudflare MSI) ...'
  $msi = Join-Path $env:TEMP 'cloudflared-windows-amd64.msi'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -Uri $CF_MSI_URL -OutFile $msi
  $sig = Get-AuthenticodeSignature $msi
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Cloudflare') { Fail "cloudflared installer signature is not a valid Cloudflare signature ($($sig.Status))." }
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
  $cfExe = @("$env:ProgramFiles\cloudflared\cloudflared.exe", "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $cfExe) { Fail 'cloudflared did not install.' }
  Write-Host "  + cloudflared installed (signed by Cloudflare)"
} else { Write-Host "  = cloudflared present" }

# === 5) Our connector =======================================================
$existing = Get-CimInstance Win32_Service -Filter "Name='$SVC'" -ErrorAction SilentlyContinue
if ($existing -and $existing.PathName -notmatch [regex]::Escape($TOKEN_FILE)) {
  Fail "a Cloudflare tunnel service that is NOT ours already exists on this PC ($($existing.PathName)). Not touching it. Tell your agent."
}
New-Item -ItemType Directory -Path $CF_DIR -Force | Out-Null
[IO.File]::WriteAllText($TOKEN_FILE, $Token)
icacls.exe $CF_DIR /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' | Out-Null
$bin = "`"$cfExe`" --no-autoupdate --logfile `"$LOG_FILE`" tunnel --protocol http2 run --token-file `"$TOKEN_FILE`""
if ($existing) { Stop-Service $SVC -Force -ErrorAction SilentlyContinue; sc.exe config $SVC binPath= $bin start= auto | Out-Null }
else { New-Service -Name $SVC -BinaryPathName $bin -DisplayName 'Cloudflared agent (BlackCEO rescue)' -StartupType Automatic | Out-Null }
sc.exe failure $SVC reset= 86400 actions= restart/20000/restart/20000/restart/60000 | Out-Null
sc.exe failureflag $SVC 1 | Out-Null
if (Test-Path $LOG_FILE) { Remove-Item $LOG_FILE -Force -ErrorAction SilentlyContinue }
Start-Service $SVC
Write-Host "  + connector service '$SVC' running (http2, auto-start, restart on failure, token in a locked file)"

# === 6) Stay reachable ======================================================
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
Write-Host '  + sleep and hibernate off while plugged in'

# === 7) Verify: up to 45s ===================================================
Write-Host ''
Write-Host '  ... verifying (up to 45s) ...'
$result = 'CHECK'
for ($i = 0; $i -lt 15; $i++) {
  Start-Sleep -Seconds 3
  $recent = if (Test-Path $LOG_FILE) { Get-Content $LOG_FILE -Tail 80 } else { @() }
  if ($recent -match 'Invalid tunnel secret|Unauthorized') { $result = 'BADTOKEN'; break }
  if (@($recent | Select-String 'Registered tunnel connection').Count -ge 2) { $result = 'PASS'; break }
}
$sshd = (Get-Service sshd).Status
$tcp22 = (Test-NetConnection -ComputerName localhost -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded
Write-Host ''
Write-Host '=================================================='
Write-Host ' SUMMARY  (rescue-install-windows v1.0)   send this to your agent'
Write-Host "   RESULT:          $result"
Write-Host "   Connector:       service $SVC"
Write-Host "   Tunnel id:       $($tok.t)"
Write-Host "   User:            $env:USERNAME   (domain\user: $me)"
Write-Host "   PC name:         $env:COMPUTERNAME"
Write-Host "   Windows:         $($os.Caption) build $($os.BuildNumber)"
Write-Host "   OpenSSH:         sshd $sshd, localhost:22 open=$tcp22"
Write-Host "   cloudflared:     $(& $cfExe --version 2>&1 | Select-Object -First 1)"
if ($Warnings.Count) { Write-Host '   WARNINGS:'; $Warnings | ForEach-Object { Write-Host "     - $_" } }
switch ($result) {
  'PASS'     { Write-Host '   >>> PASS: connector up and SSH ready.' -ForegroundColor Green }
  'BADTOKEN' { Write-Host "   >>> FAIL: BAD TOKEN. Get a fresh GENUINE token and run again." -ForegroundColor Red }
  default    { Write-Host '   >>> CHECK: no tunnel connections yet. Last lines:'; if (Test-Path $LOG_FILE) { Get-Content $LOG_FILE -Tail 6 | ForEach-Object { "       $_" } } }
}
Write-Host '=================================================='
