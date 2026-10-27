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
        [string]$Manifest
    )

    $output = & kubectl apply -f $Manifest 2>&1
    $rejected = $LASTEXITCODE -ne 0
    $detail = ($output | Select-Object -First 1 | Out-String).Trim()
    Record-Result $Name $rejected $(if ($rejected) { "admission denied the request" } else { $detail })
}

function Test-BlockedConnection {
    param(
        [string]$Name,
        [string]$FromDeployment,
        [string]$FromNamespace,
        [string]$ToService,
        [string]$ToNamespace
    )

    $python = "import socket; s=socket.socket(); s.settimeout(3); code=s.connect_ex(('$ToService.$ToNamespace.svc.cluster.local',8080)); print(code); raise SystemExit(1 if code == 0 else 0)"
    $output = & kubectl -n $FromNamespace exec "deployment/$FromDeployment" -- python -c $python 2>&1
    $blocked = $LASTEXITCODE -eq 0
    Record-Result $Name $blocked "connection result: $(($output | Out-String).Trim())"
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

$output = & kubectl -n team-dev-a exec deployment/team-a-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://nginx-a:8080/',timeout=5).status)" 2>&1
Record-Result "Team A same-namespace ingress allowed" (($LASTEXITCODE -eq 0) -and (($output | Out-String).Trim() -eq "200")) "Team A API reached nginx-a"

Test-BlockedConnection "Team A to Team B blocked" "team-a-api" "team-dev-a" "team-b-api" "team-dev-b"
Test-BlockedConnection "Team B to Team A blocked" "team-b-api" "team-dev-b" "team-a-api" "team-dev-a"

Test-Rejected "latest image rejected" "examples/admission-latest.yaml"
Test-Rejected "unapproved registry rejected" "examples/admission-untrusted-registry.yaml"
Test-Rejected "root container rejected" "examples/admission-root.yaml"
Test-Rejected "CPU quota overflow rejected" "examples/quota-cpu-exceeded.yaml"
Test-Rejected "LimitRange overflow rejected" "examples/limitrange-too-large.yaml"

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
    $sample = "import time,urllib.request; u='http://127.0.0.1:8080/'; a=[(lambda t:(urllib.request.urlopen(u,timeout=5).read(),(time.perf_counter()-t)*1000)[1])(time.perf_counter()) for _ in range(12)]; print('avg_ms=%.2f max_ms=%.2f' % (sum(a)/len(a),max(a)))"
    Write-Host "Team B latency before neighbor CPU load:"
    & kubectl -n team-dev-b exec deployment/team-b-api -- python -c $sample
    $baselineOk = $LASTEXITCODE -eq 0
    $loadReady = $false
    try {
        & kubectl apply -f examples/cpu-pressure.yaml
        if ($LASTEXITCODE -eq 0) {
            & kubectl -n team-dev-a rollout status deployment/cpu-pressure --timeout=120s
            $loadReady = $LASTEXITCODE -eq 0
        }
        if ($loadReady) {
            Write-Host "CPU usage while load is active:"
            & kubectl top pods -n team-dev-a
            Write-Host "Team B latency during neighbor CPU load:"
            & kubectl -n team-dev-b exec deployment/team-b-api -- python -c $sample
            Record-Result "Bounded CPU pressure experiment" ($baselineOk -and ($LASTEXITCODE -eq 0)) "load limited to Team A quota; inspect latency and kubectl top output"
        }
        else {
            Record-Result "Bounded CPU pressure experiment" $false "load Deployment did not become Ready"
        }
    }
    finally {
        & kubectl -n team-dev-a delete deployment cpu-pressure --ignore-not-found --wait=true
    }
}

Write-Host "Acceptance results: $script:passes passed; $script:failures failed."
if ($script:failures -gt 0) {
    exit 1
}
