# Remote deploy helper (Windows OpenSSH client → Ubuntu server)
# Usage: powershell -File scripts/remote.ps1 <check|sync|up|down|restart|logs|ps|status|pull|ssh> [extra ssh args]

param(
  [Parameter(Position = 0, Mandatory = $true)]
  [ValidateSet('check', 'sync', 'up', 'down', 'restart', 'logs', 'ps', 'status', 'pull', 'ssh', 'bind')]
  [string]$Action,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

function Read-DotEnv {
  param([string]$Path)
  $map = @{}
  if (-not (Test-Path $Path)) { return $map }
  Get-Content $Path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $eq = $line.IndexOf('=')
    if ($eq -lt 1) { return }
    $k = $line.Substring(0, $eq).Trim()
    $v = $line.Substring($eq + 1).Trim()
    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
      $v = $v.Substring(1, $v.Length - 2)
    }
    $map[$k] = $v
  }
  return $map
}

function Resolve-OpenSsh {
  param([Parameter(Mandatory = $true)][ValidateSet('ssh', 'scp')][string]$Name)

  $file = "$Name.exe"
  $candidates = @(
    # 32-bit make/powershell: Sysnative maps to real 64-bit System32
    (Join-Path $env:SystemRoot "Sysnative\OpenSSH\$file"),
    (Join-Path $env:SystemRoot "System32\OpenSSH\$file")
  )

  # where.exe (more reliable than Get-Command under make / -NoProfile)
  try {
    $whereHits = & where.exe $file 2>$null
    if ($whereHits) {
      foreach ($hit in @($whereHits)) {
        if ($hit -and (Test-Path -LiteralPath $hit)) { $candidates += $hit }
      }
    }
  } catch {}

  $gitSsh = Join-Path ${env:ProgramFiles} "Git\usr\bin\$file"
  if (Test-Path -LiteralPath $gitSsh) { $candidates += $gitSsh }

  $cmd = Get-Command $file -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
  $cmd2 = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd2 -and $cmd2.Source) { $candidates += $cmd2.Source }

  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) {
      return (Resolve-Path -LiteralPath $c).Path
    }
  }

  throw @"
Missing $file.

Your interactive shell can often see ssh while make cannot (32-bit PATH / System32 redirection).
Install OpenSSH Client, or set a full path. Expected location:
  $env:SystemRoot\System32\OpenSSH\$file
"@
}

$SshExe = Resolve-OpenSsh ssh
$ScpExe = Resolve-OpenSsh scp
Write-Host "Using SSH: $SshExe"

$envMap = Read-DotEnv (Join-Path $Root '.env')
$hostName = $envMap['DEPLOY_HOST']
$user = if ($envMap['DEPLOY_USER']) { $envMap['DEPLOY_USER'] } else { 'ubuntu' }
$deployPath = if ($envMap['DEPLOY_PATH']) { $envMap['DEPLOY_PATH'] } else { '/opt/zeroclaw' }
$sshPort = if ($envMap['DEPLOY_SSH_PORT']) { $envMap['DEPLOY_SSH_PORT'] } else { '22' }
$key = $envMap['DEPLOY_SSH_KEY']

if (-not $hostName) {
  throw "Set DEPLOY_HOST in .env (e.g. DEPLOY_HOST=myserver.example.com)"
}

$sshArgs = @('-p', $sshPort, '-o', 'StrictHostKeyChecking=accept-new')
# scp uses -P for port; -p means "preserve times" and breaks with "stat local 22"
$scpArgs = @('-P', $sshPort, '-o', 'StrictHostKeyChecking=accept-new')
if ($key) {
  if (-not (Test-Path -LiteralPath $key)) { throw "DEPLOY_SSH_KEY not found: $key" }
  $sshArgs += @('-i', $key)
  $scpArgs += @('-i', $key)
}
$target = "${user}@${hostName}"

function Invoke-Remote([string]$RemoteCmd) {
  & $SshExe @sshArgs $target $RemoteCmd
  if ($LASTEXITCODE -ne 0) { throw "Remote command failed ($LASTEXITCODE): $RemoteCmd" }
}

switch ($Action) {
  'check' {
    Write-Host "Checking SSH: ${target}:${sshPort} -> ${deployPath}"
    Invoke-Remote "echo ok && uname -a && docker --version && docker compose version"
    Write-Host "Remote OK"
  }
  'sync' {
    # Render config locally first if node is available
    if (Get-Command node -ErrorAction SilentlyContinue) {
      node (Join-Path $Root 'scripts/sync-config.js')
    }

    # Single source of truth shared with remote.sh (see scripts/deploy-manifest.txt)
    $manifest = Join-Path $Root 'scripts/deploy-manifest.txt'
    if (-not (Test-Path -LiteralPath $manifest)) {
      throw "Missing sync manifest: scripts/deploy-manifest.txt"
    }
    $files = Get-Content -LiteralPath $manifest |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -and -not $_.StartsWith('#') }

    # Remote dirs = runtime data dir + every parent directory in the manifest
    $dirs = @('data/data')
    $dirs += $files | ForEach-Object { ($_ -replace '\\', '/') } |
      Where-Object { $_.Contains('/') } |
      ForEach-Object { $_.Substring(0, $_.LastIndexOf('/')) }
    $mkdirArg = ($dirs | Sort-Object -Unique | ForEach-Object { "'${deployPath}/$_'" }) -join ' '
    Write-Host "Ensuring remote dirs under ${deployPath}"
    Invoke-Remote "mkdir -p $mkdirArg"

    foreach ($f in $files) {
      $local = Join-Path $Root $f
      if (-not (Test-Path $local)) {
        Write-Host "Skip missing $f"
        continue
      }
      $remote = "${target}:${deployPath}/$f"
      Write-Host "scp $f"
      & $ScpExe @scpArgs $local $remote
      if ($LASTEXITCODE -ne 0) { throw "scp failed: $f" }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Root 'secrets/google/credentials.json'))) {
      Write-Host "No secrets/google/credentials.json yet (see docs/google-workspace.md)"
    }

    # Drop stale gws token cache so a new refresh token's scopes take effect
    Invoke-Remote "rm -f '${deployPath}/secrets/google/token_cache.json'; rm -rf '${deployPath}/secrets/google/cache'"

    Write-Host "Synced to ${target}:${deployPath}"
  }
  'up' {
    $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Invoke-Remote "cd '${deployPath}' && docker compose build --pull --build-arg TOOLS_CACHEBUST=$bust && docker compose up -d"
  }
  'down' {
    Invoke-Remote "cd '${deployPath}' && docker compose down"
  }
  'restart' {
    Invoke-Remote "cd '${deployPath}' && docker compose restart"
  }
  'logs' {
    & $SshExe @sshArgs -t $target "cd '${deployPath}' && docker compose logs -f --tail=100"
  }
  'ps' {
    Invoke-Remote "cd '${deployPath}' && docker compose ps"
  }
  'status' {
    Invoke-Remote "cd '${deployPath}' && docker compose exec -T zeroclaw zeroclaw status --format=exit-code && echo OK"
  }
  'pull' {
    $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Invoke-Remote "cd '${deployPath}' && docker compose pull --ignore-buildable 2>/dev/null; docker compose build --pull --build-arg TOOLS_CACHEBUST=$bust"
  }
  'bind' {
    $uid = $null
    if ($Rest -and $Rest.Count -gt 0) {
      $uid = $Rest[0]
    } elseif ($envMap['TELEGRAM_ALLOWED_USERS']) {
      $uid = ($envMap['TELEGRAM_ALLOWED_USERS'] -split ',')[0].Trim()
    }
    if (-not $uid) {
      throw "Pass a Telegram user id: make remote-bind TG_USER=123456789 (or set TELEGRAM_ALLOWED_USERS)"
    }
    Write-Host "Binding Telegram user $uid on server..."
    # Schema v3: bind fills external_peers; agents must include the agent alias.
    Invoke-Remote "cd '${deployPath}' && docker compose exec -T zeroclaw zeroclaw channel bind-telegram $uid && docker compose exec -T zeroclaw zeroclaw config set peer_groups.telegram_default.agents '[`"main`"]' && docker compose restart zeroclaw"
    Write-Host "Bound. Send your Telegram message again."
  }
  'ssh' {
    if ($Rest -and $Rest.Count -gt 0) {
      $cmd = ($Rest -join ' ')
      & $SshExe @sshArgs -t $target "cd '${deployPath}' && $cmd"
    } else {
      & $SshExe @sshArgs -t $target "cd '${deployPath}' && exec `$SHELL -l"
    }
  }
}
