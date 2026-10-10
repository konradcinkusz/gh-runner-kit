# gh-runner-kit

Template and helper script for running **ephemeral, self-hosted GitHub Actions runners in Docker**, one small set per repository, on a Windows machine with Docker Desktop.

- `docker-compose.yml` – shared runner definition (image `myoung34/github-runner`).
- `new-runner.ps1` – creates a per-repo folder, writes its `.env`, starts/scales/stops runners.
- `.env.example` – shape of the per-repo `.env` (the real one lives **outside** this repo).

## Quick start

```powershell
git clone https://github.com/<you>/gh-runner-kit C:\gh-runner-kit
cd C:\gh-runner-kit
.\new-runner.ps1 -Repo LOGIN/my-repo -Count 2 -Start
```

This creates `C:\gh-runners\my-repo\` (compose copy + `.env` with `REPO_URL` and PAT) and starts 2 runners there. Run it again for another repo to get an independent folder, project name, containers and runners:

```powershell
.\new-runner.ps1 -Repo LOGIN/other-repo -Count 1 -Start
```

The PAT is read from `$env:GH_RUNNER_PAT` or prompted for. Use a **fine-grained PAT scoped to that single repo** with *Administration: Read and write*. Override the base folder with `-RunnersDir` or `$env:GH_RUNNERS_DIR`.

## Commands

| Command | Purpose |
| --- | --- |
| `.\new-runner.ps1 -Repo O/R -Count N [-Start]` | create/update folder; with `-Start` run N runners |
| `.\new-runner.ps1 list` | show per-repo folders and running runner count |
| `.\new-runner.ps1 scale -Repo O/R -Count N` | change runner count (0 = stop) |
| `.\new-runner.ps1 down -Repo O/R` | stop and remove containers |
| `.\new-runner.ps1 prune -Repo O/R` | `down` + delete the folder (incl. PAT) |
| `.\new-runner.ps1 cleanup [-OlderThan 24h]` | reclaim host disk space (see below) |

Updating the kit: `git pull`, then rerun `new` or `scale`; the compose file is refreshed, the existing `.env` is kept.

## Disk cleanup

`docker.sock` is mounted into every runner (see Security notes), so any `docker build`/`docker run`
a job does lands on the **host** Docker daemon — not inside the ephemeral runner container. Build
cache and image layers from those jobs pile up on the host disk and are never touched when a
runner exits, however many jobs run. On a busy day this can grow by tens of GB.

Run `.\new-runner.ps1 cleanup` to reclaim it: stops/removes dead containers, dangling images, and
build cache older than `-OlderThan` (default `24h`). Safe to run anytime; it never touches a
running container or an image a running container uses.

A Windows Task Scheduler task named **`gh-runner-kit cleanup`** runs it automatically: daily at
03:00, and again 3 minutes after every logon (so a machine that isn't on overnight still gets
cleaned up once it's turned on and Docker Desktop has had time to start). `-StartWhenAvailable`
means a missed 03:00 run (machine off/asleep) fires as soon as the machine is next on.

To (re)create that task:

```powershell
$action       = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\gh-runner-kit\new-runner.ps1" cleanup'
$triggerDaily = New-ScheduledTaskTrigger -Daily -At 3am
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
$triggerLogon.Delay = 'PT3M'
$settings     = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'gh-runner-kit cleanup' -Action $action `
  -Trigger @($triggerDaily, $triggerLogon) -Settings $settings -RunLevel Highest
```

Or run it by hand anytime: `.\new-runner.ps1 cleanup`.

If the host disk still runs low despite regular cleanup, the WSL2 virtual disk
(`%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`) may need compacting too: `wsl --shutdown`,
then `Optimize-VHD -Path <path> -Mode Full` (Hyper-V module) or `diskpart` → `compact vdisk`.
Pruning alone frees space *inside* Docker; the VHDX file on Windows only shrinks when compacted.

## Using the runners in a workflow

A runner only receives jobs whose `runs-on` matches its labels, and only from the repo it is registered to. Select them with a repo variable `RUNNER_LABELS` (Settings → Secrets and variables → Actions → Variables), falling back to GitHub-hosted:

```yaml
runs-on: ${{ fromJSON(vars.RUNNER_LABELS || '["ubuntu-latest"]') }}
```

Set `RUNNER_LABELS` to e.g. `["self-hosted","linux","docker"]` (must match `-Labels`).

## Security notes

- Use self-hosted runners for **private repos only**. On public repos a fork PR can run arbitrary code on your machine, and GitHub-hosted minutes are free there anyway.
- The PAT is an environment variable inside the container, so job code can read it. Keep it per-repo and minimal; never use an "All repositories" PAT.
- `docker.sock` is mounted so workflows can use Docker; that is root-equivalent on the host. Remove the volume if you don't need it.
- `.env*` is git-ignored; secrets live in `C:\gh-runners\<repo>\`, outside this repository.

## Usage and billing

Self-hosted minutes are not billed against the free quota, and Billing → Usage only lists GitHub-hosted minutes. Per-job duration and runner name are in each run's log ("Set up job"). Ephemeral runners vanish after a job, so Settings → Actions → Runners is a live view only. Hardware load: `docker stats --no-stream`; logs: `docker compose logs` inside the repo folder. GitHub has announced and paused a platform fee for self-hosted runners in private repos – check current Actions billing docs.

## Organization-level alternative

With many private repos, move them to a (free) organization and register runners at org level (`RUNNER_SCOPE=org`, `ORG_NAME=<org>` per the image README, PAT with *Self-hosted runners: Read and write*), with a runner group limited to private repos.
