<#
.SYNOPSIS
  Local control panel (browser UI) for the per-repo runners managed by new-runner.ps1.

.DESCRIPTION
  Starts a tiny web server bound to 127.0.0.1 only and opens it in your browser. It runs only
  while this window is open - no service, no scheduled task. Close the window / press Ctrl+C
  to stop it. Nothing needs to be installed (PowerShell + Docker Desktop are enough).

  Shows per repo: containers, GitHub-side runners (online / busy / offline), queued jobs, disk
  used by the repo's containers. Lets you start / scale / stop / refresh runners and delete dead
  registrations. Busy runners (a job is running in them) are never removed or restarted.

  Global: Docker disk usage, VHDX size, free space on C:, cleanup log + "clean now", and a
  ready-to-copy compact command (needs an admin shell, so the panel never runs it itself).

.EXAMPLE
  .\panel.ps1
  .\panel.ps1 -Port 9000 -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 8787,
    [string]$RunnersDir = $(if ($env:GH_RUNNERS_DIR) { $env:GH_RUNNERS_DIR } else { 'C:\gh-runners' }),
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$KitScript = Join-Path $PSScriptRoot 'new-runner.ps1'
$Template  = Join-Path $PSScriptRoot 'docker-compose.yml'
$HtmlFile  = Join-Path $PSScriptRoot 'panel.html'
$CleanupTaskName = 'gh-runner-kit cleanup'
$Inv = [Globalization.CultureInfo]::InvariantCulture

# Random per-start token: the page gets it embedded, every API call must send it back.
# Together with the Host check this blocks other websites (CSRF / DNS rebinding) from driving the panel.
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$tokBytes = New-Object byte[] 24
$rng.GetBytes($tokBytes)
$Token = -join ($tokBytes | ForEach-Object { $_.ToString('x2') })

# ---------------------------------------------------------------- helpers

function Invoke-Docker {
    # Runs docker, never throws; returns @{ Code; Out }.
    $ErrorActionPreference = 'Continue'
    $out = & docker @args 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = (($out -join "`n").Trim()) }
}

function ConvertFrom-DockerSize([string]$s) {
    if ($s -match '([\d.]+)\s*([kKMGT]?)i?B') {
        $n = [double]::Parse($Matches[1], $Inv)
        $mul = switch ($Matches[2].ToUpper()) { 'K' { 1e3 } 'M' { 1e6 } 'G' { 1e9 } 'T' { 1e12 } default { 1 } }
        return [int64]($n * $mul)
    }
    return [int64]0
}

function Read-EnvFile([string]$Dir) {
    $h = @{}
    $f = Join-Path $Dir '.env'
    if (Test-Path $f) {
        foreach ($line in Get-Content $f) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    $h
}

function Get-RepoFolders {
    if (-not (Test-Path $RunnersDir)) { return @() }
    @(Get-ChildItem $RunnersDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.env') })
}

# ---------------------------------------------------------------- GitHub

function Invoke-GH([string]$Pat, [string]$Method, [string]$Path) {
    $headers = @{
        Authorization          = "Bearer $Pat"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'gh-runner-kit-panel'
    }
    Invoke-RestMethod -Method $Method -Uri "https://api.github.com$Path" -Headers $headers -TimeoutSec 10
}

$script:ghCache = @{}   # repo -> @{ At; Data }

function Get-GitHubState([string]$Repo, [string]$Pat, [bool]$Force = $false) {
    $c = $script:ghCache[$Repo]
    if (-not $Force -and $c -and ((Get-Date) - $c.At).TotalSeconds -lt 20) { return $c.Data }
    $d = [ordered]@{ ok = $false; error = $null; online = 0; busy = 0; offline = 0; runners = @(); queued = $null; inProgress = $null }
    if (-not $Pat) { $d.error = 'brak ACCESS_TOKEN w .env' }
    else {
        try {
            $r = Invoke-GH $Pat 'GET' "/repos/$Repo/actions/runners?per_page=100"
            $list = @($r.runners | ForEach-Object {
                [ordered]@{ id = $_.id; name = $_.name; status = $_.status; busy = [bool]$_.busy }
            })
            $d.runners = $list
            $d.offline = @($list | Where-Object { $_.status -ne 'online' }).Count
            $d.busy    = @($list | Where-Object { $_.status -eq 'online' -and $_.busy }).Count
            $d.online  = @($list | Where-Object { $_.status -eq 'online' -and -not $_.busy }).Count
            $d.ok = $true
        } catch { $d.error = "runnery: $($_.Exception.Message)" }
        # Queue counts need "Actions: Read" on the PAT; optional.
        try {
            $d.queued = [int](Invoke-GH $Pat 'GET' "/repos/$Repo/actions/runs?status=queued&per_page=1").total_count
            $d.inProgress = [int](Invoke-GH $Pat 'GET' "/repos/$Repo/actions/runs?status=in_progress&per_page=1").total_count
        } catch { }
    }
    $script:ghCache[$Repo] = @{ At = Get-Date; Data = $d }
    $d
}

# ---------------------------------------------------------------- containers

function Get-Containers([string]$Project) {
    $r = Invoke-Docker ps -a -s --filter "label=com.docker.compose.project=$Project" `
        --filter 'label=com.docker.compose.service=runner' --format '{{json .}}'
    if ($r.Code -ne 0 -or -not $r.Out) { return @() }
    @($r.Out -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | ForEach-Object {
        $j = $_ | ConvertFrom-Json
        $size = if ($j.Size) { ConvertFrom-DockerSize (($j.Size -split '\(')[0]) } else { 0 }
        [pscustomobject]@{
            id = $j.ID; name = $j.Names; state = $j.State; status = $j.Status; sizeBytes = $size
            busy = $null
        }
    })
}

function Test-ContainerBusy([string]$Id) {
    # A runner executes jobs in a Runner.Worker process. The [r] keeps grep from matching itself.
    $r = Invoke-Docker exec $Id sh -c 'grep -qa "Runner.Worke[r]" /proc/[0-9]*/cmdline 2>/dev/null && echo busy || echo idle'
    if ($r.Code -ne 0) { return $true }   # cannot tell -> treat as busy (safe side)
    return ($r.Out -match 'busy')
}

function Get-ContainersWithBusy([string]$Project) {
    $cs = Get-Containers $Project
    foreach ($c in $cs) { $c.busy = if ($c.state -eq 'running') { Test-ContainerBusy $c.id } else { $false } }
    $cs
}

function Invoke-Compose([string]$Dir, [string[]]$ComposeArgs) {
    Push-Location $Dir
    try { Invoke-Docker compose @ComposeArgs } finally { Pop-Location }
}

# ---------------------------------------------------------------- disk

$script:diskCache = $null

function Get-DiskState([bool]$Force = $false) {
    if (-not $Force -and $script:diskCache -and ((Get-Date) - $script:diskCache.At).TotalSeconds -lt 30) { return $script:diskCache.Data }
    $used = [int64]0; $reclaim = [int64]0; $parts = @()
    $r = Invoke-Docker system df --format '{{json .}}'
    if ($r.Code -eq 0 -and $r.Out) {
        foreach ($line in ($r.Out -split "`n" | Where-Object { $_.Trim().StartsWith('{') })) {
            $j = $line | ConvertFrom-Json
            $sz = ConvertFrom-DockerSize $j.Size; $rc = ConvertFrom-DockerSize $j.Reclaimable
            $used += $sz; $reclaim += $rc
            $parts += [ordered]@{ type = $j.Type; size = $sz; reclaimable = $rc }
        }
    }
    $vhdx = $null
    foreach ($p in @(
            (Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'),
            (Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx'))) {
        if ($p -and (Test-Path $p)) { $vhdx = Get-Item $p; break }
    }
    $free = $null; $total = $null
    try { $di = New-Object IO.DriveInfo 'C'; $free = $di.AvailableFreeSpace; $total = $di.TotalSize } catch { }
    $vpath = if ($vhdx) { $vhdx.FullName } else { Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx' }
    $data = [ordered]@{
        dockerUsed        = $used
        dockerReclaimable = $reclaim
        breakdown         = $parts
        vhdxPath          = $vpath
        vhdxBytes         = if ($vhdx) { $vhdx.Length } else { $null }
        cFree             = $free
        cTotal            = $total
        compactCommand    = "wsl --shutdown`nOptimize-VHD -Path `"$vpath`" -Mode Full"
    }
    $script:diskCache = @{ At = Get-Date; Data = $data }
    $data
}

function Get-CleanupState {
    $log = Join-Path $RunnersDir 'cleanup.log'
    $lines = @(); if (Test-Path $log) { $lines = @(Get-Content $log -Tail 12) }
    $task = $null
    try {
        $t = Get-ScheduledTask -TaskName $CleanupTaskName -ErrorAction Stop
        $i = Get-ScheduledTaskInfo -InputObject $t
        $task = [ordered]@{ state = "$($t.State)"; lastRun = if ($i.LastRunTime -gt [datetime]'2000-01-01') { $i.LastRunTime.ToString('s') } else { $null }; nextRun = if ($i.NextRunTime) { $i.NextRunTime.ToString('s') } else { $null } }
    } catch { }
    [ordered]@{ log = $lines; task = $task }
}

# ---------------------------------------------------------------- state

function Get-State([bool]$Force = $false) {
    $repos = @(foreach ($d in Get-RepoFolders) {
        $e = Read-EnvFile $d.FullName
        $project = if ($e['COMPOSE_PROJECT_NAME']) { $e['COMPOSE_PROJECT_NAME'] } else { $d.Name }
        $repo = $null
        if ($e['REPO_URL'] -match 'github\.com/([\w.-]+/[\w.-]+?)(?:\.git)?/?$') { $repo = $Matches[1] }
        $cs = @(Get-ContainersWithBusy $project)
        $gh = if ($repo) { Get-GitHubState $repo $e['ACCESS_TOKEN'] $Force } else { [ordered]@{ ok = $false; error = 'nieznany REPO_URL'; runners = @() } }
        $running = @($cs | Where-Object { $_.state -eq 'running' })
        [ordered]@{
            name       = $d.Name
            repo       = $repo
            labels     = $e['RUNNER_LABELS']
            containers = $cs
            running    = $running.Count
            idle       = @($running | Where-Object { -not $_.busy }).Count
            busyLocal  = @($running | Where-Object { $_.busy }).Count
            sizeBytes  = [int64](($cs | Measure-Object sizeBytes -Sum).Sum)
            github     = $gh
        }
    })
    [ordered]@{
        time       = (Get-Date).ToString('s')
        runnersDir = $RunnersDir
        repos      = $repos
        disk       = Get-DiskState $Force
        cleanup    = Get-CleanupState
    }
}

# ---------------------------------------------------------------- actions

function Resolve-Folder([string]$Name) {
    $f = Get-RepoFolders | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if (-not $f) { throw "Nieznane repo: $Name" }
    $f
}

function Set-RunnerCount($Folder, [int]$Count) {
    # Scale to $Count. Scaling down only removes stopped/idle containers - busy ones are kept.
    if ($Count -lt 0 -or $Count -gt 32) { throw 'Liczba runnerow musi byc 0-32' }
    $e = Read-EnvFile $Folder.FullName
    $project = if ($e['COMPOSE_PROJECT_NAME']) { $e['COMPOSE_PROJECT_NAME'] } else { $Folder.Name }
    Copy-Item $Template (Join-Path $Folder.FullName 'docker-compose.yml') -Force
    $cs = @(Get-ContainersWithBusy $project)
    $skipped = 0
    if ($Count -lt $cs.Count) {
        $need = $cs.Count - $Count
        # removable: not running first, then idle ones; busy ones are never touched
        $removable = @($cs | Where-Object { -not $_.busy } | Sort-Object { $_.state -eq 'running' })
        $take = [Math]::Min($need, $removable.Count)
        foreach ($c in ($removable | Select-Object -First $take)) { [void](Invoke-Docker rm -f $c.id) }
        $skipped = $need - $take
        $cs = @(Get-Containers $project)
    }
    $target = [Math]::Max($Count, $cs.Count)   # never ask compose to go below what is still busy
    if ($target -eq 0) { $r = Invoke-Compose $Folder.FullName @('down') }
    else { $r = Invoke-Compose $Folder.FullName @('up', '-d', '--scale', "runner=$target", '--no-recreate', '--remove-orphans') }
    if ($r.Code -ne 0) { throw "docker compose: $($r.Out)" }
    $msg = "Runnery: $target"
    if ($skipped -gt 0) { $msg += " (pominieto $skipped zajetych - zakoncza prace, wtedy ponow Stop/zmiane liczby)" }
    $msg
}

function Invoke-Refresh($Folder) {
    # Recreate idle containers (fresh state). Busy ones are left alone.
    $e = Read-EnvFile $Folder.FullName
    $project = if ($e['COMPOSE_PROJECT_NAME']) { $e['COMPOSE_PROJECT_NAME'] } else { $Folder.Name }
    $cs = @(Get-ContainersWithBusy $project)
    if ($cs.Count -eq 0) { throw 'Brak kontenerow do odswiezenia - uzyj Start' }
    $idle = @($cs | Where-Object { -not $_.busy })
    foreach ($c in $idle) { [void](Invoke-Docker rm -f $c.id) }
    $r = Invoke-Compose $Folder.FullName @('up', '-d', '--scale', "runner=$($cs.Count)", '--no-recreate', '--remove-orphans')
    if ($r.Code -ne 0) { throw "docker compose: $($r.Out)" }
    "Odswiezono $($idle.Count), pominieto zajetych: $($cs.Count - $idle.Count)"
}

function Remove-DeadRegistrations($Folder) {
    $e = Read-EnvFile $Folder.FullName
    if ($e['REPO_URL'] -notmatch 'github\.com/([\w.-]+/[\w.-]+?)(?:\.git)?/?$') { throw 'Nieznany REPO_URL' }
    $repo = $Matches[1]
    $gh = Get-GitHubState $repo $e['ACCESS_TOKEN'] $true
    if (-not $gh.ok) { throw $gh.error }
    $removed = 0; $failed = 0
    foreach ($r in @($gh.runners | Where-Object { $_.status -ne 'online' })) {
        try { Invoke-GH $e['ACCESS_TOKEN'] 'DELETE' "/repos/$repo/actions/runners/$($r.id)" | Out-Null; $removed++ } catch { $failed++ }
    }
    [void](Get-GitHubState $repo $e['ACCESS_TOKEN'] $true)
    "Usunieto martwych rejestracji: $removed" + $(if ($failed) { ", bledow: $failed" } else { '' })
}

function Invoke-CleanupNow {
    $hostExe = (Get-Process -Id $PID).Path
    $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $KitScript cleanup -RunnersDir $RunnersDir 2>&1 | ForEach-Object { "$_" }
    $script:diskCache = $null
    ($out -join "`n").Trim()
}

# ---------------------------------------------------------------- http

function Send-Response($Ctx, [int]$Status, [string]$Body, [string]$Type = 'application/json; charset=utf-8') {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Ctx.Response.StatusCode = $Status
    $Ctx.Response.ContentType = $Type
    $Ctx.Response.Headers['Cache-Control'] = 'no-store'
    $Ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Ctx.Response.Headers['X-Frame-Options'] = 'DENY'
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-Json($Ctx, [int]$Status, $Obj) {
    Send-Response $Ctx $Status (ConvertTo-Json -InputObject $Obj -Depth 10 -Compress)
}

function Read-Body($Ctx) {
    if (-not $Ctx.Request.HasEntityBody) { return $null }
    $sr = New-Object IO.StreamReader($Ctx.Request.InputStream, [Text.Encoding]::UTF8)
    try { $t = $sr.ReadToEnd() } finally { $sr.Dispose() }
    if ($t) { $t | ConvertFrom-Json } else { $null }
}

function Invoke-Request($Ctx) {
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    $allowedHosts = @("127.0.0.1:$Port", "localhost:$Port")
    if ($allowedHosts -notcontains $req.Headers['Host']) { return Send-Json $Ctx 403 @{ error = 'forbidden host' } }

    if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
        $html = (Get-Content $HtmlFile -Raw -Encoding UTF8).Replace('__PANEL_TOKEN__', $Token)
        return Send-Response $Ctx 200 $html 'text/html; charset=utf-8'
    }
    if (-not $path.StartsWith('/api/')) { return Send-Json $Ctx 404 @{ error = 'not found' } }
    if ($req.Headers['X-Panel-Token'] -ne $Token) { return Send-Json $Ctx 403 @{ error = 'bad token' } }

    try {
        if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/state') {
            $force = $req.QueryString['force'] -eq '1'
            return Send-Json $Ctx 200 (Get-State $force)
        }
        if ($req.HttpMethod -ne 'POST') { return Send-Json $Ctx 405 @{ error = 'method not allowed' } }
        $body = Read-Body $Ctx

        if ($path -eq '/api/cleanup') {
            return Send-Json $Ctx 200 @{ message = 'Sprzatanie zakonczone'; output = (Invoke-CleanupNow) }
        }
        if ($path -match '^/api/repo/([\w.-]+)/(start|scale|stop|refresh|remove-dead)$') {
            $folder = Resolve-Folder $Matches[1]
            $action = $Matches[2]
            $msg = switch ($action) {
                { $_ -in 'start', 'scale' } {
                    $n = if ($body -and $null -ne $body.count) { [int]$body.count } else { 1 }
                    if ($n -lt 1) { throw 'Liczba musi byc >= 1 (do zatrzymania uzyj Stop)' }
                    Set-RunnerCount $folder $n
                }
                'stop'        { Set-RunnerCount $folder 0 }
                'refresh'     { Invoke-Refresh $folder }
                'remove-dead' { Remove-DeadRegistrations $folder }
            }
            $script:ghCache.Clear()
            return Send-Json $Ctx 200 @{ message = "$msg" }
        }
        Send-Json $Ctx 404 @{ error = 'not found' }
    } catch {
        Send-Json $Ctx 500 @{ error = "$($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------- main

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker not found in PATH (start Docker Desktop)' }
if (-not (Test-Path $HtmlFile)) { throw "Missing $HtmlFile" }

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { throw "Cannot listen on 127.0.0.1:$Port ($($_.Exception.Message)). Try -Port." }

$url = "http://127.0.0.1:$Port/"
Write-Host "gh-runner-kit panel: $url   (Ctrl+C to stop; only reachable from this computer)"
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(500)) { }   # keeps Ctrl+C responsive
        $ctx = $task.GetAwaiter().GetResult()
        try { Invoke-Request $ctx }
        catch { try { Send-Json $ctx 500 @{ error = "$($_.Exception.Message)" } } catch { } }
        finally { try { $ctx.Response.Close() } catch { } }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
