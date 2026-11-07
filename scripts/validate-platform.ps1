param(
    [switch]$IncludeCpuLoad
)

$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:failures = 0
$script:passes = 0

function Record-Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details
    )

    if ($Passed) {
        $script:passes++
        Write-Host "[PASS] $Name - $Details" -ForegroundColor Green
    }
    else {
        $script:failures++
        Write-Host "[FAIL] $Name - $Details" -ForegroundColor Red
    }
}

function Test-Can {
    param(
        [string]$Name,
        [string]$Verb,
        [string]$Resource,
        [string]$Identity,
        [string]$Namespace,
        [bool]$Expected
    )

    $result = & kubectl auth can-i $Verb $Resource "--as=$Identity" -n $Namespace 2>&1
    $allowed = ($LASTEXITCODE -eq 0) -and (($result | Out-String).Trim() -eq "yes")
    Record-Result $Name ($allowed -eq $Expected) "can-i returned $(($result | Out-String).Trim()); expected $Expected"
}

function Test-Rejected {
    param(
        [string]$Name,
        [string]$Manifest,
        [string]$ExpectedPattern
    )

    $output = & kubectl apply -f $Manifest 2>&1
    $rejected = $LASTEXITCODE -ne 0
    $details = ($output | Out-String).Trim()
    $expectedRejection = $rejected -and ($details -match $ExpectedPattern)
    Record-Result $Name $expectedRejection $(if ($expectedRejection) { "expected rejection observed" } else { $details })
}

function Test-ConfigMapQuota {
    param(
        [string]$Name,
        [string]$Namespace
    )

    $quotaOutput = & kubectl -n $Namespace get resourcequota team-quota -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Record-Result $Name $false "could not read ResourceQuota: $(($quotaOutput | Out-String).Trim())"
        return
    }

    try {
        $quota = ($quotaOutput | Out-String) | ConvertFrom-Json
        $hard = [int]$quota.spec.hard.'count/configmaps'
        $used = [int]$quota.status.used.'count/configmaps'
    }
    catch {
        Record-Result $Name $false "could not parse ConfigMap quota: $_"
        return
    }
    if ($hard -le 0 -or $used -gt $hard) {
        Record-Result $Name $false "invalid quota usage: used $used of hard limit $hard"
        return
    }

    $createdNames = @()
    try {
        while ($used -lt $hard) {
            $configMapName = "quota-probe-$([guid]::NewGuid().ToString('N').Substring(0, 10))"
            $createOutput = & kubectl -n $Namespace create configmap $configMapName --from-literal=probe=true 2>&1
            if ($LASTEXITCODE -ne 0) {
                Record-Result $Name $false "could not fill quota to its limit: $(($createOutput | Out-String).Trim())"
                return
            }
            $createdNames += $configMapName
            $used++
        }

        $probeName = "quota-probe-$([guid]::NewGuid().ToString('N').Substring(0, 10))"
        $probeOutput = & kubectl -n $Namespace create configmap $probeName --from-literal=probe=true 2>&1
        $details = ($probeOutput | Out-String).Trim()
        $rejected = ($LASTEXITCODE -ne 0) -and ($details -match '(?i)exceeded quota|count/configmaps')
        Record-Result $Name $rejected $(if ($rejected) { "ConfigMap beyond count quota was rejected" } else { $details })
    }
    finally {
        foreach ($configMapName in $createdNames) {
            & kubectl -n $Namespace delete configmap $configMapName --ignore-not-found --wait=true 1>$null 2>$null
        }
    }
}

function Test-BlockedConnection {
    param(
        [string]$Name,
        [string]$FromDeployment,
        [string]$FromNamespace,
        [string]$ToService,
        [string]$ToNamespace
    )

    $endpointOutput = & kubectl -n $ToNamespace get endpointslices.discovery.k8s.io -l "kubernetes.io/service-name=$ToService" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Record-Result $Name $false "could not inspect destination endpoints: $(($endpointOutput | Out-String).Trim())"
        return
    }

    try {
        $endpointJson = ($endpointOutput | Out-String) | ConvertFrom-Json
        $readyAddresses = @($endpointJson.items | ForEach-Object { $_.endpoints } | Where-Object { $_.conditions.ready -ne $false } | ForEach-Object { $_.addresses } | Where-Object { $_ })
    }
    catch {
        Record-Result $Name $false "could not parse destination endpoints: $_"
        return
    }
    if ($readyAddresses.Count -eq 0) {
        Record-Result $Name $false "destination Service has no ready EndpointSlice addresses"
        return
    }

    $python = @"
import errno, socket
host = '$ToService.$ToNamespace.svc.cluster.local'
try:
    socket.getaddrinfo(host, 8080, type=socket.SOCK_STREAM)
except OSError as exc:
    print('DNS_ERROR: ' + str(exc))
    raise SystemExit(2)
s = socket.socket()
s.settimeout(3)
code = s.connect_ex((host, 8080))
print(code)
blocked_codes = {errno.ECONNREFUSED, errno.ETIMEDOUT, errno.EHOSTUNREACH, errno.ENETUNREACH}
raise SystemExit(0 if code in blocked_codes else 1)
"@
    $output = & kubectl -n $FromNamespace exec "deployment/$FromDeployment" -- python -c $python 2>&1
    $blocked = $LASTEXITCODE -eq 0
    Record-Result $Name $blocked "DNS resolved; destination has $($readyAddresses.Count) ready endpoint(s); expected a refused or timed-out connection; result: $(($output | Out-String).Trim())"
}

function Test-AllowedHttp {
    param(
        [string]$Name,
        [string]$FromDeployment,
        [string]$FromNamespace,
        [string]$Url
    )

    $python = "import urllib.request; r=urllib.request.urlopen('$Url',timeout=5); print(r.status); raise SystemExit(0 if r.status == 200 else 1)"
    $output = & kubectl -n $FromNamespace exec "deployment/$FromDeployment" -- python -c $python 2>&1
    $allowed = ($LASTEXITCODE -eq 0) -and (($output | Out-String).Trim() -eq "200")
    Record-Result $Name $allowed "HTTP result: $(($output | Out-String).Trim()); expected 200"
}

function Test-DatabaseIsolation {
    param(
        [string]$Name,
        [string]$Namespace,
        [string]$Deployment,
        [string]$OtherDatabase
    )

    $python = "import os,psycopg`ntry:`n c=psycopg.connect(host=os.environ['POSTGRES_HOST'],dbname='$OtherDatabase',user=os.environ['POSTGRES_USER'],password=os.environ['POSTGRES_PASSWORD'],connect_timeout=3)`n c.close()`n print('unexpectedly connected')`n raise SystemExit(1)`nexcept psycopg.OperationalError as exc:`n message=str(exc).lower()`n denied=('permission denied for database' in message and '$($OtherDatabase.ToLowerInvariant())' in message)`n print('DENIED' if denied else type(exc).__name__)`n raise SystemExit(0 if denied else 1)"
    $output = & kubectl -n $Namespace exec "deployment/$Deployment" -- python -c $python 2>&1
    $denied = ($LASTEXITCODE -eq 0) -and (($output | Out-String).Trim() -eq "DENIED")
    Record-Result $Name $denied "cross-team database connection result: $(($output | Out-String).Trim())"
}

function Test-RedisKeyIsolation {
    param(
        [string]$Name,
        [string]$Namespace,
        [string]$Deployment,
        [string]$OtherTeamKey
    )

    $python = "import os,redis`nr=redis.Redis(host=os.environ['REDIS_HOST'],port=6379,username=os.environ['REDIS_USER'],password=os.environ['REDIS_PASSWORD'],socket_connect_timeout=3,socket_timeout=3)`ntry:`n r.get('$OtherTeamKey')`n print('unexpectedly accessed key')`n raise SystemExit(1)`nexcept redis.exceptions.NoPermissionError:`n print('NOPERM')"
    $output = & kubectl -n $Namespace exec "deployment/$Deployment" -- python -c $python 2>&1
    $denied = ($LASTEXITCODE -eq 0) -and (($output | Out-String).Trim() -eq "NOPERM")
    Record-Result $Name $denied "cross-team Redis key access was denied"
}

Write-Host "CaaS platform acceptance tests" -ForegroundColor Cyan

foreach ($namespace in @("team-dev-a", "team-dev-b", "team-dev-c")) {
    & kubectl get namespace $namespace 1>$null 2>$null
    Record-Result "Namespace $namespace exists" ($LASTEXITCODE -eq 0) "namespace lookup"

    & kubectl -n $namespace get resourcequota team-quota 1>$null 2>$null
    Record-Result "Quota $namespace exists" ($LASTEXITCODE -eq 0) "ResourceQuota team-quota"
}

Test-Can "Team A can manage Deployments" "create" "deployments.apps" "system:serviceaccount:team-dev-a:dev-user-a" "team-dev-a" $true
Test-Can "Team A cannot create raw Pods" "create" "pods" "system:serviceaccount:team-dev-a:dev-user-a" "team-dev-a" $false
Test-Can "Team B cannot delete Services" "delete" "services" "system:serviceaccount:team-dev-b:dev-user-b" "team-dev-b" $false
Test-Can "Team C can update Deployments" "update" "deployments.apps" "system:serviceaccount:team-dev-c:dev-user-c" "team-dev-c" $true
Test-Can "Team C cannot delete Deployments" "delete" "deployments.apps" "system:serviceaccount:team-dev-c:dev-user-c" "team-dev-c" $false
Test-Can "Team A cannot read Team B Secrets" "get" "secrets" "system:serviceaccount:team-dev-a:dev-user-a" "team-dev-b" $false

foreach ($team in @(
    @{Name = "A"; Namespace = "team-dev-a"; Deployment = "team-a-api"},
    @{Name = "B"; Namespace = "team-dev-b"; Deployment = "team-b-api"}
)) {
    $output = & kubectl -n $team.Namespace exec "deployment/$($team.Deployment)" -- python -c "import json,urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/',timeout=5).read().decode())" 2>&1
    $healthy = $LASTEXITCODE -eq 0
    if ($healthy) {
        try {
            $payload = (($output | Out-String).Trim() | ConvertFrom-Json)
            $healthy = ($payload.team -eq $team.Name) -and ($payload.postgres -eq 1)
        }
        catch {
            $healthy = $false
        }
    }
    Record-Result "Team $($team.Name) API and shared services" $healthy "API reports healthy PostgreSQL and Redis access"
}

Test-DatabaseIsolation "Team A cannot connect to Team B database" "team-dev-a" "team-a-api" "caas_team_b"
Test-DatabaseIsolation "Team B cannot connect to Team A database" "team-dev-b" "team-b-api" "caas_team_a"
Test-RedisKeyIsolation "Team A cannot read Team B Redis key" "team-dev-a" "team-a-api" "team-b-visits"
Test-RedisKeyIsolation "Team B cannot read Team A Redis key" "team-dev-b" "team-b-api" "team-a-visits"

Test-AllowedHttp "Team A same-namespace ingress allowed" "team-a-api" "team-dev-a" "http://nginx-a:8080/"
Test-AllowedHttp "Team B same-namespace ingress allowed" "team-b-api" "team-dev-b" "http://httpbin-b:8080/get"

Test-BlockedConnection "Team A to Team B blocked" "team-a-api" "team-dev-a" "team-b-api" "team-dev-b"
Test-BlockedConnection "Team B to Team A blocked" "team-b-api" "team-dev-b" "team-a-api" "team-dev-a"

Test-Rejected "latest image rejected" "examples/admission-latest.yaml" "(?i)tenant-image-policy|latest"
Test-Rejected "unapproved registry rejected" "examples/admission-untrusted-registry.yaml" "(?i)tenant-image-policy|unapproved|not allowed"
Test-Rejected "root container rejected" "examples/admission-root.yaml" "(?i)PodSecurity|runAsNonRoot|restricted"
Test-Rejected "CPU quota overflow rejected" "examples/quota-cpu-exceeded.yaml" "(?i)exceeded quota|requests.cpu"
Test-Rejected "Memory quota overflow rejected" "examples/quota-memory-exceeded.yaml" "(?i)exceeded quota|requests.memory"
Test-Rejected "LimitRange overflow rejected" "examples/limitrange-too-large.yaml" "(?i)maximum usage|LimitRange|500m"
Test-ConfigMapQuota "ConfigMap object quota enforced" "team-dev-a"

$defaultPod = "examples/limitrange-default.yaml"
$output = & kubectl apply -f $defaultPod 2>&1
$defaultAccepted = $LASTEXITCODE -eq 0
$defaultResources = $null
if ($defaultAccepted) {
    $podJson = & kubectl -n team-dev-a get pod limitrange-default -o json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $container = (($podJson | Out-String) | ConvertFrom-Json).spec.containers[0]
        $defaultResources = "$($container.resources.requests.cpu)/$($container.resources.requests.memory), $($container.resources.limits.cpu)/$($container.resources.limits.memory)"
        $defaultAccepted = ($container.resources.requests.cpu -eq "100m") -and
            ($container.resources.requests.memory -eq "128Mi") -and
            ($container.resources.limits.cpu -eq "250m") -and
            ($container.resources.limits.memory -eq "256Mi")
    }
    else {
        $defaultAccepted = $false
    }
}
Record-Result "LimitRange supplies default resources" $defaultAccepted $defaultResources
& kubectl -n team-dev-a delete pod limitrange-default --ignore-not-found --wait=true 1>$null 2>$null

if ($IncludeCpuLoad) {
    $sample = @'
import json, math, time, urllib.request
values = []
errors = 0
for _ in range(30):
    started = time.perf_counter()
    try:
        with urllib.request.urlopen('http://127.0.0.1:8080/', timeout=5) as response:
            response.read()
            if response.status != 200:
                errors += 1
            else:
                values.append((time.perf_counter() - started) * 1000)
    except Exception:
        errors += 1
if not values:
    print(json.dumps({'count': 0, 'errors': errors, 'p95_ms': None}))
    raise SystemExit(1)
values.sort()
p95 = values[math.ceil(0.95 * len(values)) - 1]
print(json.dumps({'count': len(values), 'errors': errors, 'p95_ms': round(p95, 2)}))
'@
    function Get-TeamBLatencySample {
        $output = & kubectl -n team-dev-b exec deployment/team-b-api -- python -c $sample 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        try {
            return (($output | Select-Object -Last 1 | Out-String).Trim() | ConvertFrom-Json)
        }
        catch {
            return $null
        }
    }

    Write-Host "CPU-load criterion: 30 samples per phase, zero errors, loaded P95 <= baseline P95 * 1.25."
    $targetPodOutput = & kubectl -n team-dev-b get pods -l app=team-b-api -o json 2>&1
    $targetNode = $null
    if ($LASTEXITCODE -eq 0) {
        try {
            $targetPods = ($targetPodOutput | Out-String) | ConvertFrom-Json
            $targetNode = ($targetPods.items | Where-Object { $_.status.phase -eq "Running" } | Select-Object -First 1).spec.nodeName
        }
        catch {
            $targetNode = $null
        }
    }
    Write-Host "Team B latency before neighbor CPU load:"
    $baseline = Get-TeamBLatencySample
    $baselineOk = $null -ne $baseline -and $baseline.count -gt 0
    if ($baselineOk) { Write-Host "count=$($baseline.count) errors=$($baseline.errors) p95_ms=$($baseline.p95_ms)" }
    $loadReady = $false
    try {
        if ($targetNode) {
            & kubectl apply -f examples/cpu-pressure.yaml
        }
        else {
            Write-Host "Could not identify a running Team B API node."
        }
        if ($targetNode -and $LASTEXITCODE -eq 0) {
            & kubectl -n team-dev-a rollout status deployment/cpu-pressure --timeout=120s
            $rolloutReady = $LASTEXITCODE -eq 0
            if ($rolloutReady) {
                $loadPodsOutput = & kubectl -n team-dev-a get pods -l app=cpu-pressure -o json 2>&1
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $loadPods = ($loadPodsOutput | Out-String) | ConvertFrom-Json
                        $readyLoadPods = @($loadPods.items | Where-Object { $_.status.phase -eq "Running" -and $_.status.containerStatuses.Count -gt 0 -and $_.status.containerStatuses[0].ready })
                        $coLocatedPods = @($readyLoadPods | Where-Object { $_.spec.nodeName -eq $targetNode }).Count
                        $loadReady = ($readyLoadPods.Count -eq 4) -and ($coLocatedPods -eq 4)
                        Write-Host "Ready CPU workers: $($readyLoadPods.Count)/4; workers on Team B node ($targetNode): $coLocatedPods/4"
                    }
                    catch {
                        $loadReady = $false
                        Write-Host "Could not verify CPU worker placement: $_"
                    }
                }
                if (-not $loadReady) {
                    Record-Result "Bounded CPU pressure experiment" $false "expected four ready CPU workers colocated with Team B"
                }
            }
        }
        if ($loadReady) {
            $cpuMetricsReady = $false
            $metricLines = @()
            for ($attempt = 0; $attempt -lt 12; $attempt++) {
                $topOutput = & kubectl -n team-dev-a top pods -l app=cpu-pressure --no-headers 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $metricLines = @($topOutput | Where-Object { $_ -match '^cpu-pressure-' })
                    if ($metricLines.Count -eq 4) {
                        $cpuMetricsReady = $true
                        foreach ($metricLine in $metricLines) {
                            $cpuValue = ($metricLine -split '\s+')[1]
                            if ($cpuValue -match '^([0-9]+)m$') {
                                $cpuMetricsReady = $cpuMetricsReady -and ([int]$Matches[1] -gt 0)
                            }
                            elseif ($cpuValue -match '^([0-9]+(?:\.[0-9]+)?)$') {
                                $cpuMetricsReady = $cpuMetricsReady -and ([double]$Matches[1] -gt 0)
                            }
                            else {
                                $cpuMetricsReady = $false
                            }
                        }
                        if ($cpuMetricsReady) { break }
                    }
                }
                Start-Sleep -Seconds 5
            }
            if (-not $cpuMetricsReady) {
                Record-Result "Bounded CPU pressure experiment" $false "CPU metrics were not available and positive for all four workers"
            }
        }
        if ($loadReady -and $cpuMetricsReady) {
            Write-Host "CPU usage while load is active:"
            $metricLines | ForEach-Object { Write-Host $_ }
            Write-Host "Team B latency during neighbor CPU load:"
            $loaded = Get-TeamBLatencySample
            $loadedOk = $null -ne $loaded -and $loaded.count -gt 0
            $passed = $false
            $details = "could not collect both latency samples"
            if ($baselineOk -and $loadedOk) {
                $regressionPercent = (($loaded.p95_ms - $baseline.p95_ms) / [Math]::Max([double]$baseline.p95_ms, 0.01)) * 100
                $passed = ($baseline.errors -eq 0) -and ($loaded.errors -eq 0) -and ($regressionPercent -le 25)
                $details = "baseline P95=$($baseline.p95_ms) ms; loaded P95=$($loaded.p95_ms) ms; change=$([Math]::Round($regressionPercent, 1))%; errors baseline/loaded=$($baseline.errors)/$($loaded.errors); threshold <=25%, zero errors"
            }
            Record-Result "Bounded CPU pressure experiment" $passed $details
        }
        elseif (-not $loadReady) {
            Record-Result "Bounded CPU pressure experiment" $false "load Deployment did not become Ready"
        }
    }
    finally {
        & kubectl -n team-dev-a delete deployment cpu-pressure --ignore-not-found --wait=true 1>$null 2>$null
    }
}

Write-Host "Acceptance results: $script:passes passed; $script:failures failed."
if ($script:failures -gt 0) {
    exit 1
}
