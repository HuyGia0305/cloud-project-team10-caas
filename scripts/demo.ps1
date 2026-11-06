<#
  demo.ps1 - Demo nen tang CaaS (Nhom 10, UTH) cho buoi bao cao.
  Cach chay (trong thu muc repo, vi du C:\caas-project):
    powershell -ExecutionPolicy Bypass -File .\scripts\demo.ps1            # bam Enter de sang buoc tiep (de thuyet trinh)
    powershell -ExecutionPolicy Bypass -File .\scripts\demo.ps1 -Auto      # tu chay, moi buoc cach nhau 4 giay
    powershell -ExecutionPolicy Bypass -File .\scripts\demo.ps1 -Full      # cuoi demo chay them validate-platform.ps1 (31 kiem tra, ~2-3 phut)
#>
param(
    [switch]$Auto,
    [switch]$Full,
    [int]$Delay = 4
)

$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
$script:ok = 0
$script:bad = 0

function Step([string]$title, [string]$say) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host $title -ForegroundColor Cyan
    Write-Host ("  Noi voi thay: " + $say) -ForegroundColor DarkGray
    Write-Host ("=" * 78) -ForegroundColor Cyan
    if ($Auto) { Start-Sleep -Seconds $Delay } else { Read-Host "  [Enter de chay]" | Out-Null }
}

function Show([string]$cmd) {
    Write-Host ("PS> " + $cmd) -ForegroundColor Yellow
    Invoke-Expression $cmd 2>&1 | ForEach-Object { $_.ToString() } | Where-Object { $_ -and $_ -notmatch 'RemoteException' } | Write-Host
}

function Check([string]$name, [bool]$pass, [string]$detail) {
    if ($pass) { $script:ok++; Write-Host ("[PASS] " + $name + " - " + $detail) -ForegroundColor Green }
    else { $script:bad++; Write-Host ("[FAIL] " + $name + " - " + $detail) -ForegroundColor Red }
}

function Expect-Rejected([string]$name, [string]$file) {
    Write-Host ("PS> kubectl apply -f " + $file) -ForegroundColor Yellow
    $out = & kubectl apply -f $file 2>&1 | ForEach-Object { $_.ToString() }
    $rejected = $LASTEXITCODE -ne 0
    ($out | Where-Object { $_ -and $_ -notmatch 'RemoteException' } | Select-Object -First 4) | Write-Host
    Check $name $rejected $(if ($rejected) { "bi tu choi dung ky vong" } else { "KHONG bi tu choi (bat thuong)" })
    if (-not $rejected) { & kubectl delete -f $file --ignore-not-found 2>&1 | Out-Null }
}

function Expect-Port([string]$name, [string]$ns, [string]$deploy, [string]$host_, [int]$port, [bool]$shouldConnect) {
    $py = "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('$host_',$port)))"
    $out = (& kubectl -n $ns exec "deployment/$deploy" -- python -c $py 2>&1 | Out-String).Trim()
    $code = ($out -split "`n")[-1].Trim()
    $connected = ($code -eq "0")
    Write-Host ("  ket qua connect_ex = " + $code + "  (0 = ket noi duoc, 111 = bi tu choi)")
    Check $name ($connected -eq $shouldConnect) $(if ($shouldConnect) { "ket noi duoc nhu mong doi" } else { "bi chan nhu mong doi" })
}

function Expect-Can([string]$name, [string]$verb, [string]$res, [string]$sa, [string]$ns, [bool]$expected) {
    $r = (& kubectl auth can-i $verb $res "--as=$sa" -n $ns 2>&1 | Out-String).Trim()
    Check $name (($r -eq "yes") -eq $expected) ("can-i tra ve '" + $r + "', ky vong " + $(if ($expected) { "yes" } else { "no" }))
}

Clear-Host
Write-Host "DEMO NEN TANG CaaS NHOM 10 - Quota, RBAC, NetworkPolicy, Admission, Giam sat" -ForegroundColor White

# ---------------- 0. Cum ----------------
Step "BUOC 0 - Cum Kubernetes (k3d: 1 server + 2 agent)" "Toan bo chay cuc bo tren Docker, chi phi 0 dong."
Show "kubectl get nodes -o wide"
Show "kubectl get ns | Select-String 'team|kyverno|monitoring'"
$ready = (& kubectl get nodes --no-headers 2>$null | Select-String " Ready").Count
Check "Cum co 3 node Ready" ($ready -eq 3) ("so node Ready = " + $ready)

# ---------------- 1. Tai nguyen ----------------
Step "BUOC 1 - Quota va LimitRange cho tung nhom" "Moi nhom toi da 1 CPU/1Gi requests, 2 CPU/2Gi limits, 6 Pod; Pod khong khai bao se duoc gan mac dinh."
Show "kubectl get resourcequota -A"
Show "kubectl get limitrange -A"
Show "kubectl get pods -A | Select-String 'team-dev|team-shared'"

# ---------------- 2. RBAC ----------------
Step "BUOC 2 - RBAC toi thieu (phan quyen theo nhom)" "Moi nhom chi quan ly Deployment trong namespace cua minh, khong doc Secret cua nhom khac."
Expect-Can "Team A tao duoc Deployment" "create" "deployments.apps" "system:serviceaccount:team-dev-a:dev-user-a" "team-dev-a" $true
Expect-Can "Team A KHONG tao duoc Pod tran" "create" "pods" "system:serviceaccount:team-dev-a:dev-user-a" "team-dev-a" $false
Expect-Can "Team A KHONG doc duoc Secret cua Team B" "get" "secrets" "system:serviceaccount:team-dev-a:dev-user-a" "team-dev-b" $false
Expect-Can "Team B KHONG xoa duoc Service" "delete" "services" "system:serviceaccount:team-dev-b:dev-user-b" "team-dev-b" $false

# ---------------- 3. Admission ----------------
Step "BUOC 3 - Admission: Kyverno + Pod Security + Quota tu choi yeu cau sai" "PASS o day nghia la yeu cau xau BI TU CHOI - co che bao ve hoat dong dung."
Expect-Rejected "Image tag latest bi tu choi" "examples/admission-latest.yaml"
Expect-Rejected "Registry la bi tu choi" "examples/admission-untrusted-registry.yaml"
Expect-Rejected "Container chay root bi tu choi" "examples/admission-root.yaml"
Expect-Rejected "Vuot quota CPU bi tu choi" "examples/quota-cpu-exceeded.yaml"
Expect-Rejected "Vuot LimitRange bi tu choi" "examples/limitrange-too-large.yaml"

# ---------------- 4. LimitRange mac dinh ----------------
Step "BUOC 4 - Pod khong khai bao tai nguyen duoc LimitRange gan mac dinh" "Mong doi: request 100m/128Mi, limit 250m/256Mi."
Write-Host "PS> kubectl apply -f examples/limitrange-default.yaml" -ForegroundColor Yellow
& kubectl apply -f examples/limitrange-default.yaml 2>&1 | ForEach-Object { $_.ToString() } | Write-Host
Start-Sleep -Seconds 3
Show "kubectl -n team-dev-a get pod limitrange-default -o jsonpath='{.spec.containers[0].resources}'"
Write-Host ""
Write-Host "  (don dep pod mau)" -ForegroundColor DarkGray
& kubectl delete -f examples/limitrange-default.yaml --ignore-not-found 2>&1 | Out-Null

# ---------------- 5. Mang ----------------
Step "BUOC 5 - NetworkPolicy: mac dinh tu choi, chi mo luong can thiet" "A toi PostgreSQL/Redis dung chung duoc phep; A <-> B va A -> C bi chan."
Expect-Port "Team A -> PostgreSQL dung chung :5432 (cho phep)" "team-dev-a" "team-a-api" "shared-postgres.team-shared.svc.cluster.local" 5432 $true
Expect-Port "Team A -> Redis dung chung :6379 (cho phep)" "team-dev-a" "team-a-api" "shared-redis.team-shared.svc.cluster.local" 6379 $true
Expect-Port "Team A -> API Team B :8080 (bi chan)" "team-dev-a" "team-a-api" "team-b-api.team-dev-b.svc.cluster.local" 8080 $false
Expect-Port "Team B -> API Team A :8080 (bi chan)" "team-dev-b" "team-b-api" "team-a-api.team-dev-a.svc.cluster.local" 8080 $false
Expect-Port "Team A -> nginx Team C :8080 (bi chan)" "team-dev-a" "team-a-api" "team-c-web.team-dev-c.svc.cluster.local" 8080 $false

# ---------------- 6. Cach ly du lieu ----------------
Step "BUOC 6 - Cach ly du lieu: moi nhom 1 database/role/Redis ACL rieng" "Team A khong the ket noi database cua Team B."
$py = "import os,psycopg`ntry:`n c=psycopg.connect(host=os.environ['POSTGRES_HOST'],dbname='caas_team_b',user=os.environ['POSTGRES_USER'],password=os.environ['POSTGRES_PASSWORD'],connect_timeout=3)`n c.close()`n print('KET NOI DUOC (bat thuong)')`nexcept psycopg.OperationalError as e:`n print('DENIED' if 'permission denied' in str(e).lower() else 'LOI: ' + str(e))"
$raw = & kubectl -n team-dev-a exec deployment/team-a-api -- python -c $py 2>&1 | ForEach-Object { $_.ToString() } | Where-Object { $_ -and $_ -notmatch 'RemoteException' }
$o = ($raw | Select-Object -Last 3) -join " | "
Write-Host ("  ket qua: " + $o)
Check "Team A khong vao duoc database cua Team B" ($o -like "*DENIED*") ($(if ($o -like "*DENIED*") { "permission denied nhu mong doi" } else { $o }))

# ---------------- 7. Giam sat ----------------
Step "BUOC 7 - Giam sat Prometheus/Grafana" "Mo them 1 cua so PowerShell va chay lenh port-forward ben duoi, roi mo trinh duyet."
Show "kubectl -n monitoring get pods | Select-String 'grafana|prometheus'"
Write-Host ""
Write-Host "  Mo Grafana (cua so PowerShell MOI):" -ForegroundColor Yellow
$gsvc = (& kubectl -n monitoring get svc -o name 2>$null | Where-Object { $_ -match 'grafana' } | Select-Object -First 1)
if (-not $gsvc) { $gsvc = "svc/monitoring-grafana" }
Write-Host ("    kubectl -n monitoring port-forward " + $gsvc + " 3000:80")
Write-Host "    Trinh duyet: http://localhost:3000  -> Dashboards -> Kubernetes / Compute Resources / Namespace (Pods) -> team-dev-a"
Write-Host "    (Neu ten service khac: kubectl -n monitoring get svc | Select-String grafana)"
Write-Host "    Tai khoan: admin ; lay mat khau bang lenh:"
Write-Host "    kubectl -n monitoring get secret grafana-admin -o jsonpath=`"{.data.admin-password}`" | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$_)) }"

# ---------------- 8. Full ----------------
if ($Full) {
    Step "BUOC 8 - Chay lai toan bo ma tran kiem thu tu dong" "validate-platform.ps1 kiem tra RBAC, admission, mang, du lieu."
    & "$PSScriptRoot\validate-platform.ps1"
}

# ---------------- Tong ket ----------------
Write-Host ""
Write-Host ("=" * 78) -ForegroundColor Cyan
$color = if ($script:bad -eq 0) { "Green" } else { "Red" }
Write-Host ("TONG KET DEMO: " + $script:ok + " dat, " + $script:bad + " khong dat") -ForegroundColor $color
Write-Host "Ghi chu: 'dat' o cac buoc tu choi nghia la yeu cau xau bi chan dung ky vong." -ForegroundColor DarkGray
Write-Host ("=" * 78) -ForegroundColor Cyan
