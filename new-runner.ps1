<#
.SYNOPSIS
  Manage per-repository ephemeral GitHub Actions runners (Docker Compose).

.DESCRIPTION
  Keeps one folder per repo under $RunnersDir (default C:\gh-runners) containing a copy
  of docker-compose.yml and a private .env (PAT). Secrets never live in this repo.

.EXAMPLE
  .\new-runner.ps1 -Repo LOGIN/my-repo -Count 2 -Start     # create (or update) and start
  .\new-runner.ps1 list
  .\new-runner.ps1 scale -Repo LOGIN/my-repo -Count 1
  .\new-runner.ps1 down  -Repo LOGIN/my-repo
  .\new-runner.ps1 prune -Repo LOGIN/my-repo               # down + delete folder
  .\new-runner.ps1 cleanup                                 # reclaim disk: stopped containers, dangling images, old build cache

.NOTES
  Runners mount /var/run/docker.sock, so any `docker build`/`docker run` a job does
  lands on the HOST Docker daemon, not inside the ephemeral runner container. That
  cache and those layers never get cleaned by the runner exiting - run `cleanup`
  regularly (see README for scheduling it as a daily Task Scheduler job).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('new', 'list', 'scale', 'down', 'prune', 'cleanup')]
    [string]$Action = 'new',
    [string]$Repo,                       # OWNER/NAME
    [int]$Count = 1,
    [switch]$Start,
    [string]$Labels = 'self-hosted,linux,docker',
    [string]$RunnersDir = $(if ($env:GH_RUNNERS_DIR) { $env:GH_RUNNERS_DIR } else { 'C:\gh-runners' }),
    [string]$OlderThan = '24h'           # cleanup: age filter for unused images/build cache
)

$ErrorActionPreference = 'Stop'
$Template = Join-Path $PSScriptRoot 'docker-compose.yml'

function Get-RepoDir {
    if ($Repo -notmatch '^[\w.-]+/[\w.-]+$') { throw "-Repo must look like OWNER/NAME" }
    Join-Path $RunnersDir ($Repo.Split('/')[1].ToLower())
}

function Invoke-Compose([string]$Dir, [string[]]$ComposeArgs) {
    Push-Location $Dir
    try { & docker compose @ComposeArgs; if ($LASTEXITCODE) { throw "docker compose failed" } }
    finally { Pop-Location }
}

switch ($Action) {
    'new' {
        if (-not $Repo) { throw '-Repo is required' }
        if ($Count -lt 1) { throw '-Count must be >= 1' }
        $dir = Get-RepoDir
        $name = Split-Path $dir -Leaf
        New-Item -ItemType Directory -Force $dir | Out-Null
        Copy-Item $Template (Join-Path $dir 'docker-compose.yml') -Force
        $envFile = Join-Path $dir '.env'
        if (-not (Test-Path $envFile)) {
            $pat = $env:GH_RUNNER_PAT
            if (-not $pat) {
                $sec = Read-Host "Fine-grained PAT for $Repo (Administration: Read and write)" -AsSecureString
                $pat = [System.Net.NetworkCredential]::new('', $sec).Password
            }
            @(
                "REPO_URL=https://github.com/$Repo"
                "ACCESS_TOKEN=$pat"
                "RUNNER_LABELS=$Labels"
                "COMPOSE_PROJECT_NAME=$name"
            ) | Set-Content -Path $envFile -Encoding ascii
            Write-Host "Created $envFile"
        } else { Write-Host "Keeping existing $envFile" }
        if ($Start) { Invoke-Compose $dir @('up', '-d', '--scale', "runner=$Count", '--remove-orphans') }
        else { Write-Host "Ready. Start with: .\new-runner.ps1 scale -Repo $Repo -Count $Count" }
    }
    'scale' {
        if (-not $Repo) { throw '-Repo is required' }
        $dir = Get-RepoDir
        if (-not (Test-Path $dir)) { throw "No folder for $Repo - run 'new' first" }
        Copy-Item $Template (Join-Path $dir 'docker-compose.yml') -Force
        if ($Count -eq 0) { Invoke-Compose $dir @('down') }
        else { Invoke-Compose $dir @('up', '-d', '--scale', "runner=$Count", '--remove-orphans') }
    }
    'down' {
        if (-not $Repo) { throw '-Repo is required' }
        Invoke-Compose (Get-RepoDir) @('down')
    }
    'prune' {
        if (-not $Repo) { throw '-Repo is required' }
        $dir = Get-RepoDir
        if (Test-Path (Join-Path $dir 'docker-compose.yml')) { Invoke-Compose $dir @('down', '--volumes') }
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force; Write-Host "Removed $dir" }
        Write-Host "Offline runners may remain in GitHub: Settings > Actions > Runners."
    }
    'cleanup' {
        Write-Host "Pruning stopped containers..."
        docker container prune -f
        Write-Host "Pruning dangling images..."
        docker image prune -f
        Write-Host "Pruning build cache older than $OlderThan..."
        docker builder prune -f --filter "until=$OlderThan"
    }
    'list' {
        if (-not (Test-Path $RunnersDir)) { Write-Host "No runners yet ($RunnersDir)"; return }
        Get-ChildItem $RunnersDir -Directory | ForEach-Object {
            $url = (Select-String -Path (Join-Path $_.FullName '.env') -Pattern '^REPO_URL=(.*)$' -ErrorAction SilentlyContinue).Matches.Groups[1].Value
            $running = @(docker ps --filter "label=com.docker.compose.project=$($_.Name)" --format '{{.Names}}').Count
            [pscustomobject]@{ Folder = $_.Name; Repo = $url; Running = $running }
        } | Format-Table -AutoSize
    }
}
