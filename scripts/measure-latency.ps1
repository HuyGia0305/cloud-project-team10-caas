# measure-latency.ps1
# Collects RAW latency samples of the Team B API with and without CPU load from Team A.
# - Samples are measured INSIDE the team-b-api pod (127.0.0.1:8080), so kubectl/port-forward overhead is excluded.
# - The CPU-load Deployment (examples/cpu-pressure.yaml) is pinned to the SAME node as team-b-api,
#   otherwise there is no noisy-neighbor effect to observe.
# - Phase order alternates between runs (odd: baseline first, even: load first) to reduce order bias.
# Output: evidence/latency-samples.csv (raw) and evidence/latency-run-info.txt (conditions).
# Run from the repo root:  .\scripts\measure-latency.ps1
# Then:                    python scripts\plot-latency.py
param(
    [int]$Runs = 5,
    [int]$Samples = 100,
    [int]$CooldownSeconds = 20,
    [switch]$NoColocate
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$teamNs   = "team-dev-b"
$teamDep  = "team-b-api"
$loadNs   = "team-dev-a"
$loadYaml = "examples/cpu-pressure.yaml"
$samplesCsv = "evidence/latency-samples.csv"
$infoTxt    = "evidence/latency-run-info.txt"
$tmpYaml    = Join-Path $env:TEMP "cpu-pressure-colocated.yaml"
$ExpectedLoadPods = 4

$py = @'
import sys, time, urllib.request
n = int(sys.argv[1])
def one():
    t = time.perf_counter()
    try:
        r = urllib.request.urlopen("http://127.0.0.1:8080/", timeout=5)
        r.read()
        ok = (r.status == 200)
    except Exception:
        ok = False
    return (time.perf_counter() - t) * 1000.0, ok
for _ in range(5):
    one()
for i in range(1, n + 1):
    ms, ok = one()
    print("%d,%.2f,%s" % (i, ms, "ok" if ok else "error"))
    time.sleep(0.05)
'@

function Get-TeamBNode {
    $j = kubectl -n $teamNs get pods -l app=$teamDep -o json | ConvertFrom-Json
    if (-not $j.items -or $j.items.Count -lt 1) { throw "No pod found for $teamDep in $teamNs" }
    return $j.items[0].spec.nodeName
}

function Get-LoadNodes {
    $j = kubectl -n $loadNs get pods -l app=cpu-pressure -o json | ConvertFrom-Json
    return @($j.items | Where-Object { $_.status.phase -eq "Running" } | ForEach-Object { $_.spec.nodeName })
}

function Start-Load {
    kubectl apply -f $tmpYaml | Out-Null
    kubectl -n $loadNs rollout status deployment/cpu-pressure --timeout=180s | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cpu-pressure did not become ready, so the CPU load is NOT running. Check: kubectl -n $loadNs get pods" }
    $running = @(Get-LoadNodes).Count
    if ($running -ne $ExpectedLoadPods) { throw "Only $running of $ExpectedLoadPods cpu-pressure pods are Running, so the CPU load is incomplete." }
    Start-Sleep -Seconds 5
}

function Stop-Load {
    kubectl delete -f $tmpYaml --ignore-not-found --wait=true | Out-Null
    Start-Sleep -Seconds $CooldownSeconds
}

function Get-Samples([int]$RunId, [string]$Scenario, [int]$Order) {
    $raw = $py | kubectl -n $teamNs exec -i "deployment/$teamDep" -- python - $Samples
    $rows = @()
    foreach ($line in $raw) {
        if ($line -match '^(\d+),([0-9.]+),(ok|error)$') {
            $rows += [pscustomobject]@{
                run_id       = $RunId
                scenario     = $Scenario
                order_in_run = $Order
                sample_no    = [int]$Matches[1]
                latency_ms   = [double]::Parse($Matches[2], [System.Globalization.CultureInfo]::InvariantCulture)
                status       = $Matches[3]
            }
        }
    }
    if ($rows.Count -ne $Samples) { Write-Warning "Run $RunId $Scenario collected $($rows.Count) of $Samples samples" }
    return $rows
}

# --- Preconditions ---
kubectl -n $teamNs get deployment $teamDep | Out-Null
kubectl -n $loadNs get pods -l app=cpu-pressure -o name | ForEach-Object { throw "Leftover cpu-pressure pods exist in $loadNs. Delete them first: kubectl delete -f $loadYaml" }

# --- Build the load manifest ---
$yaml = Get-Content $loadYaml -Raw
$node = Get-TeamBNode
if (-not $NoColocate) {
    $yaml = [regex]::Replace($yaml, '(?s) {6}affinity:.*?(?= {6}containers:)', "      nodeSelector:`n        kubernetes.io/hostname: $node`n")
    if ($yaml -notmatch 'nodeSelector') { throw "Could not rewrite the affinity block in $loadYaml" }
}
Set-Content -Path $tmpYaml -Value $yaml -Encoding ASCII

New-Item -ItemType Directory -Force -Path "evidence" | Out-Null
$all = @()
$loadNodesSeen = @()
$k8sVersion = (kubectl version -o json | ConvertFrom-Json).serverVersion.gitVersion

try {
    for ($run = 1; $run -le $Runs; $run++) {
        $baselineFirst = ($run % 2 -eq 1)
        Write-Host "=== Run $run / $Runs (baseline first: $baselineFirst) ===" -ForegroundColor Cyan
        if ($baselineFirst) {
            $all += Get-Samples $run "baseline" 1
            Start-Load
            $loadNodesSeen += Get-LoadNodes
            $all += Get-Samples $run "cpu_load" 2
            Stop-Load
        } else {
            Start-Load
            $loadNodesSeen += Get-LoadNodes
            $all += Get-Samples $run "cpu_load" 1
            Stop-Load
            $all += Get-Samples $run "baseline" 2
        }
        $b = ($all | Where-Object { $_.run_id -eq $run -and $_.scenario -eq "baseline" } | Measure-Object latency_ms -Average).Average
        $l = ($all | Where-Object { $_.run_id -eq $run -and $_.scenario -eq "cpu_load" } | Measure-Object latency_ms -Average).Average
        Write-Host ("  mean baseline = {0:N2} ms, mean cpu_load = {1:N2} ms" -f $b, $l)
    }
}
finally {
    kubectl delete -f $tmpYaml --ignore-not-found | Out-Null
}

$all | Export-Csv -Path $samplesCsv -NoTypeInformation -Encoding UTF8

$colocated = ($loadNodesSeen | Where-Object { $_ -ne $node }).Count -eq 0
@(
    "date: $(Get-Date -Format 's')",
    "kubernetes: $k8sVersion",
    "target: $teamNs/$teamDep on node $node",
    "load: $loadNs/cpu-pressure (4 replicas, request 200m / limit 250m each)",
    "load nodes observed (Running pods only): $((($loadNodesSeen | Sort-Object -Unique) -join ', '))",
    "running load pods verified at the start of every load phase: $ExpectedLoadPods",
    "load colocated with target on every run: $colocated",
    "runs: $Runs, samples per scenario per run: $Samples, warm-up requests discarded: 5",
    "pause between requests: 50 ms, cooldown after load: $CooldownSeconds s",
    "phase order alternates (odd runs baseline first, even runs load first)"
) | Set-Content -Path $infoTxt -Encoding UTF8

if (-not $colocated) { Write-Warning "Load pods were NOT all on the same node as the target. Results are not a valid noisy-neighbor test." }
Write-Host "Saved $samplesCsv and $infoTxt. Next: python scripts\plot-latency.py" -ForegroundColor Green
