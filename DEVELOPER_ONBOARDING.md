# Hướng dẫn triển khai CaaS cho Developer

Các lệnh được chạy tại thư mục gốc của repo. Bước tạo Secret dùng PowerShell; các bước còn lại dùng CMD hoặc PowerShell.

Repo: https://github.com/HuyGia0305/cloud-project-team10-caas

## 1. Công cụ và cụm k3d

Mở Docker Desktop, sau đó kiểm tra:

    docker version
    k3d version
    kubectl version --client

Xem cụm hiện có:

    k3d cluster list

Nếu caas-phat-lab đã có nhưng đang dừng, chạy:

    k3d cluster start caas-phat-lab

Nếu chưa có cụm, tạo 1 server và 2 agent:

    k3d cluster create caas-phat-lab --servers 1 --agents 2

Chọn context của cụm và kiểm tra:

    kubectl config use-context k3d-caas-phat-lab
    kubectl get nodes
    kubectl get storageclass

Ba node phải ở trạng thái Ready. PostgreSQL và stack giám sát dùng StorageClass `local-path`.

## 2. Namespace, giới hạn tài nguyên và tài khoản nhóm

Tạo ba namespace nhóm và namespace dùng chung. `team-shared` dành cho PostgreSQL/Redis; namespace `monitoring` và `kyverno` được Helm tạo riêng:

    kubectl apply -f namespaces/tenants.yaml

Áp dụng LimitRange và ResourceQuota cho cả ba nhóm cùng dịch vụ dùng chung:

    kubectl apply -f limitrange-team-a.yaml
    kubectl apply -f limitrange-team-b.yaml
    kubectl apply -f limitrange-team-c.yaml
    kubectl apply -f resourcequota-team-a.yaml
    kubectl apply -f resourcequota-team-b.yaml
    kubectl apply -f resourcequota-team-c.yaml
    kubectl apply -f shared-resourcequota.yaml
    kubectl apply -f security/default-serviceaccounts.yaml

Áp dụng NetworkPolicy **trước khi triển khai workload**: tạo ngoại lệ cần thiết trước, rồi mới bật deny mặc định:

    kubectl apply -f networkpolicy-team-a.yaml
    kubectl apply -f networkpolicy-team-b.yaml
    kubectl apply -f networkpolicy-team-c.yaml
    kubectl apply -f network-policy-allow-shared.yaml
    kubectl apply -f network-policy-deny-all.yaml

Tạo ba ServiceAccount và RoleBinding riêng:

    kubectl apply -f rbac-team-a.yaml
    kubectl apply -f rbac-team-b.yaml
    kubectl apply -f rbac-team-c.yaml

Team A có quyền CRUD Deployment/Service/ConfigMap nhưng không tạo Pod trực tiếp; Team B không xóa Service/ConfigMap; Team C chỉ tạo/cập nhật Deployment, không xóa workload. Không nhóm nào được đọc Secret hoặc tạo quyền ở namespace khác. Pod Security Admission dùng mức `restricted` cho ba namespace nhóm; ServiceAccount mặc định không tự mount token.

### Cài Kyverno và bật quy tắc nhận workload

Chính sách phải được cài trước khi deploy ứng dụng:

    helm repo add kyverno https://kyverno.github.io/kyverno/
    helm repo update
    helm upgrade --install kyverno kyverno/kyverno --version 3.9.2 --namespace kyverno --create-namespace --values kyverno/values.yaml --wait --timeout 10m
    kubectl apply -f kyverno/policies.yaml

Xác minh Kyverno và policy đã sẵn sàng:

    kubectl -n kyverno get pods
    kubectl get clusterpolicy tenant-image-policy

Policy chỉ cho phép image có tag phiên bản hoặc digest từ `docker.io`, `ghcr.io`, `registry.k8s.io`; từ chối `latest`, registry khác và container không non-root/khai báo requests-limits/tắt privilege escalation/drop capabilities. Namespace `team-dev-a/b/c` đồng thời dùng Pod Security Admission `restricted`. Policy hiện **không xác minh chữ ký/provenance Cosign**; xem giới hạn và hướng nâng cấp trong [REPORT.md](REPORT.md).

Xem giới hạn đang áp dụng:

    kubectl -n team-dev-a describe limitrange container-limits
    kubectl -n team-dev-a describe resourcequota team-quota
    kubectl -n team-dev-b describe limitrange container-limits
    kubectl -n team-dev-b describe resourcequota team-quota

| Giới hạn mỗi team | Giá trị |
|---|---:|
| Số Pod | 6 |
| Tổng CPU requests / limits | 1 / 2 cores |
| Tổng RAM requests / limits | 1Gi / 2Gi |

Mỗi container có CPU từ 50m đến 500m và RAM từ 64Mi đến 512Mi. Nếu manifest không khai báo, request mặc định là 100m/128Mi, limit mặc định là 250m/256Mi. Kiểm tra cột Used/Hard của ResourceQuota trước khi thêm Pod. Khi đổi quota, đối chiếu với CPU/RAM của cụm cùng Huy.

## 3. Secret PostgreSQL và Redis theo nhóm

Chạy phần này bằng PowerShell trên cụm mới. Tạo một mật khẩu quản trị PostgreSQL và hai mật khẩu tenant riêng; không đưa giá trị vào Git. Ví dụ dưới đây sinh giá trị ngẫu nhiên 256-bit, dùng chung một mật khẩu riêng cho từng team ở PostgreSQL và Redis, rồi tạo Secret quản trị trong `team-shared` và Secret ứng dụng chỉ trong namespace tương ứng:

    function New-RandomSecretValue {
      $bytes = New-Object byte[] 32
      $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
      try {
        $generator.GetBytes($bytes)
        [Convert]::ToBase64String($bytes)
      } finally {
        $generator.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
      }
    }

    $adminPassword = New-RandomSecretValue
    $teamAPassword = New-RandomSecretValue
    $teamBPassword = New-RandomSecretValue
    try {
      kubectl -n team-shared create secret generic shared-postgres-auth `
        --from-literal="POSTGRES_PASSWORD=$adminPassword" `
        --from-literal="TEAM_A_PASSWORD=$teamAPassword" `
        --from-literal="TEAM_B_PASSWORD=$teamBPassword"
      kubectl -n team-dev-a create secret generic team-a-db-auth `
        --from-literal="POSTGRES_PASSWORD=$teamAPassword" `
        --from-literal="REDIS_PASSWORD=$teamAPassword"
      kubectl -n team-dev-b create secret generic team-b-db-auth `
        --from-literal="POSTGRES_PASSWORD=$teamBPassword" `
        --from-literal="REDIS_PASSWORD=$teamBPassword"
    } finally {
      Remove-Variable adminPassword, teamAPassword, teamBPassword -ErrorAction SilentlyContinue
    }

Mỗi Secret chỉ tạo một lần; nếu đã tồn tại, không chạy lại các lệnh `create`. Không cấp Secret DB cho Team C vì workload mẫu của nhóm này không dùng DB/Redis. Không đổi mật khẩu khi PVC PostgreSQL đã có dữ liệu: script khởi tạo database/role chỉ chạy khi PostgreSQL khởi tạo thư mục dữ liệu lần đầu. Muốn đổi mật khẩu trên PVC hiện có, cần thực hiện migration/rotation có kế hoạch đồng bộ DB role, Redis ACL và các Secret ứng dụng. Không đưa mật khẩu vào Git.

## 4. PostgreSQL và Redis dùng chung

    kubectl apply -f manifests/apps/postgres-init.yaml
    kubectl apply -f manifests/apps/team-shared.yaml
    kubectl -n team-shared rollout status deployment/shared-postgres --timeout=180s
    kubectl -n team-shared rollout status deployment/shared-redis --timeout=180s
    kubectl -n team-shared get pods,svc,pvc

PVC shared-postgres-data phải ở trạng thái Bound. Kiểm tra hai dịch vụ:

    kubectl -n team-shared exec deployment/shared-postgres -- pg_isready -U caas -d caas
    kubectl -n team-shared exec deployment/shared-redis -- sh -c 'REDISCLI_AUTH="$TEAM_A_REDIS_PASSWORD" redis-cli --user team_a ping'

PostgreSQL trả về accepting connections; Redis trả về PONG với ACL user Team A. Tài khoản `team_a` và `team_b` chỉ được dùng key prefix riêng của nhóm; PostgreSQL có database/role riêng cho từng nhóm.

## 5. API Team A và Team B

Hai API viết bằng Python, có endpoint `/metrics` cho Prometheus và lấy mật khẩu PostgreSQL/Redis từ Secret riêng trong namespace. Build đúng tên image theo allowlist Kyverno:

    docker build -t ghcr.io/team10/caas-team-a-api:v1 apps/team-a
    docker build -t ghcr.io/team10/caas-team-b-api:v1 apps/team-b
    k3d image import ghcr.io/team10/caas-team-a-api:v1 --cluster caas-phat-lab
    k3d image import ghcr.io/team10/caas-team-b-api:v1 --cluster caas-phat-lab
    kubectl apply -f manifests/apps/team-a.yaml
    kubectl apply -f manifests/apps/team-b.yaml
    kubectl -n team-dev-a rollout status deployment/team-a-api --timeout=180s
    kubectl -n team-dev-b rollout status deployment/team-b-api --timeout=180s

Import image trước khi áp dụng manifest vì hai Deployment đặt `imagePullPolicy: Never`. Tạo lại cụm thì phải import lại image. Tài khoản developer chỉ quản lý workload trong namespace của chính nhóm.

## 6. Nginx và HTTPBin

    kubectl apply -f manifests/apps/nginx-team-a.yaml
    kubectl apply -f manifests/apps/httpbin-team-b.yaml
    kubectl apply -f manifests/apps/team-c.yaml
    kubectl -n team-dev-a rollout status deployment/nginx-a --timeout=180s
    kubectl -n team-dev-b rollout status deployment/httpbin-b --timeout=180s
    kubectl -n team-dev-c rollout status deployment/team-c-web --timeout=180s

Nginx ở team-dev-a, HTTPBin ở team-dev-b và Nginx ở team-dev-c; cả ba có Service cổng 8080.

## 7. NetworkPolicy

    kubectl get networkpolicy -A

Pod cùng team được kết nối với nhau. HTTP/TCP giữa các team bị chặn. Ba team được dùng DNS và truy cập PostgreSQL cổng 5432, Redis cổng 6379 trong `team-shared`. Prometheus được phép scrape API qua TCP 8080. Không dùng ping làm phép thử kết luận vì Kubernetes NetworkPolicy không bảo đảm chặn ICMP.

## 8. Kiểm thử

Gọi từng API. Trường postgres phải bằng 1; redis_visits là bộ đếm tăng sau mỗi lần gọi:

    kubectl -n team-dev-a exec deployment/team-a-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/', timeout=5).read().decode())"
    kubectl -n team-dev-b exec deployment/team-b-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/', timeout=5).read().decode())"

Gọi Nginx và HTTPBin qua Service; cả hai trả mã 200:

    kubectl -n team-dev-a exec deployment/team-a-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://nginx-a:8080/', timeout=5).status)"
    kubectl -n team-dev-b exec deployment/team-b-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://httpbin-b:8080/get', timeout=5).status)"

API Team A/B phải cung cấp Prometheus metrics:

    kubectl -n team-dev-a exec deployment/team-a-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/metrics', timeout=5).read().decode()[:300])"
    kubectl apply -f manifests/apps/team-api-servicemonitors.yaml
    kubectl apply -f monitoring/tenant-dashboard.yaml

Tạo client thử nghiệm đã khai báo tài nguyên và security context:

    kubectl apply -f examples/network-smoke.yaml
    kubectl -n team-dev-a exec pod/network-client-a -- wget -T 3 -qO- http://nginx-a:8080/
    kubectl -n team-dev-c exec pod/network-client-c -- wget -T 3 -qO- http://team-c-web:8080/

Hai lệnh HTTP cùng namespace phải thành công. Thử kết nối chéo. Cả hai lệnh phải in ra số khác 0:

    kubectl -n team-dev-a exec deployment/team-a-api -- python -c "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('team-b-api.team-dev-b.svc.cluster.local', 8080)))"
    kubectl -n team-dev-b exec deployment/team-b-api -- python -c "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('team-a-api.team-dev-a.svc.cluster.local', 8080)))"

Thử truy cập dịch vụ DB được cho phép từ Team C:

    kubectl -n team-dev-c exec pod/network-client-c -- nc -z -w 3 shared-postgres.team-shared.svc.cluster.local 5432

Xóa các Pod thử sau khi kiểm tra:

    kubectl delete -f examples/network-smoke.yaml

Thử LimitRange mặc định:

    kubectl apply -f examples/limitrange-default.yaml
    kubectl -n team-dev-a get pod limitrange-default -o jsonpath="{.spec.containers[0].resources}"

Pod phải có requests 100m/128Mi và limits 250m/256Mi. Các manifest kiểm thử sau phải bị từ chối:

    kubectl apply -f examples/limitrange-too-large.yaml
    kubectl apply -f examples/quota-cpu-exceeded.yaml
    kubectl apply -f examples/admission-latest.yaml
    kubectl apply -f examples/admission-untrusted-registry.yaml
    kubectl apply -f examples/admission-root.yaml

Sau khi thử xong, xóa Pod thử để trả lại quota:

    kubectl -n team-dev-a delete pod limitrange-default

Ma trận kiểm thử lặp lại và bài đo tải tùy chọn:

    .\scripts\validate-platform.ps1
    .\scripts\validate-platform.ps1 -IncludeCpuLoad

Bài tải chạy tối đa bốn Pod CPU loop trong Team A (200m request/250m limit mỗi Pod) và tự xóa Deployment sau khi đo; không bỏ giới hạn tài nguyên.

## 9. Xem ứng dụng trên máy cá nhân

Chạy một lệnh port-forward trong terminal riêng. Mở URL ở cột bên phải; nhấn Ctrl+C để dừng.

| Ứng dụng | Lệnh | URL |
|---|---|---|
| API Team A | kubectl -n team-dev-a port-forward svc/team-a-api 8080:8080 | http://localhost:8080/ |
| API Team B | kubectl -n team-dev-b port-forward svc/team-b-api 8081:8080 | http://localhost:8081/ |
| Nginx Team A | kubectl -n team-dev-a port-forward svc/nginx-a 8082:8080 | http://localhost:8082/ |
| HTTPBin Team B | kubectl -n team-dev-b port-forward svc/httpbin-b 8083:8080 | http://localhost:8083/get |
| Web Team C | kubectl -n team-dev-c port-forward svc/team-c-web 8084:8080 | http://localhost:8084/ |

## 10. Địa chỉ Service cho giám sát

| Dịch vụ | Địa chỉ trong cụm |
|---|---|
| API Team A | team-a-api.team-dev-a.svc.cluster.local:8080 |
| API Team B | team-b-api.team-dev-b.svc.cluster.local:8080 |
| Nginx Team A | nginx-a.team-dev-a.svc.cluster.local:8080 |
| HTTPBin Team B | httpbin-b.team-dev-b.svc.cluster.local:8080 |
| PostgreSQL | shared-postgres.team-shared.svc.cluster.local:5432 |
| Redis | shared-redis.team-shared.svc.cluster.local:6379 |
| Web Team C | team-c-web.team-dev-c.svc.cluster.local:8080 |

## 11. Prometheus và Grafana qua Helm

`kube-prometheus-stack` cài Prometheus, Grafana, Prometheus Operator, kube-state-metrics và Node Exporter. Cấu hình trong `monitoring/values.yaml` giới hạn tài nguyên, lưu dữ liệu bằng StorageClass `local-path`, giữ dữ liệu Prometheus 7 ngày và dùng Secret riêng cho mật khẩu Grafana. Cài stack sau khi cụm và StorageClass đã sẵn sàng.

Cài Helm nếu máy chưa có, sau đó kiểm tra công cụ và context:

    helm version
    kubectl config current-context
    kubectl get nodes
    kubectl get storageclass

Tạo namespace và Secret mật khẩu Grafana bằng PowerShell. Nhập mật khẩu thay vì lưu trong repo:

    kubectl create namespace monitoring
    $grafanaPassword = Read-Host "Nhap mat khau Grafana"
    kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal="admin-password=$grafanaPassword"
    Remove-Variable grafanaPassword

Nếu namespace đã tồn tại, bỏ qua lệnh tạo namespace. Nếu Secret `grafana-admin` đã tồn tại, không cần tạo lại. Không đưa mật khẩu vào Git.

Cài hoặc cập nhật stack bằng Helm:

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack --version 92.14.0 --namespace monitoring --values monitoring/values.yaml --wait --timeout 10m
    kubectl apply -f manifests/apps/team-api-servicemonitors.yaml
    kubectl apply -f monitoring/tenant-dashboard.yaml

Kiểm tra các Pod và PVC đã sẵn sàng:

    kubectl -n monitoring get pods
    kubectl -n monitoring get pvc
    kubectl -n monitoring rollout status deployment/monitoring-grafana --timeout=180s
    kubectl -n monitoring get prometheus

Mở Grafana trong terminal riêng. Nếu cần xem lại mật khẩu đã lưu trong Secret, dùng lệnh PowerShell sau; đăng nhập bằng tên `admin`:

    kubectl -n monitoring get secret grafana-admin -o jsonpath="{.data.admin-password}" | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }

Sau đó chạy port-forward:

    kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80

Truy cập http://localhost:3000. Prometheus đã được cấu hình làm data source; dashboard Kubernetes có sẵn hiển thị node/Pod và dashboard **CaaS - tài nguyên theo nhóm** hiển thị CPU/RAM, số Pod, quota và request rate theo team. API A/B phát metrics; Team C dùng nginx nên chỉ có resource metrics.

    kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090

Truy cập http://localhost:9090. Dừng port-forward bằng Ctrl+C. Để xác nhận các API được scrape, mở **Status → Targets** hoặc truy vấn `up{namespace=~"team-dev-a|team-dev-b"}`.

Gỡ stack nếu không còn sử dụng (dữ liệu PVC không tự bị xóa):

    helm uninstall monitoring --namespace monitoring

## 12. Báo cáo và kiểm thử

[REPORT.md](REPORT.md) mô tả câu hỏi nghiên cứu, mô hình CaaS, giới hạn multi-tenancy, cấu hình quyền/chính sách, ma trận thử nghiệm và kết quả đo workload lân cận. Chụp ảnh dashboard Grafana làm minh chứng khi nộp báo cáo.

## 13. Khi gặp lỗi

- ErrImageNeverPull ở API: kiểm tra image bằng docker image ls, import lại bằng k3d image import, rồi chạy kubectl rollout restart cho Deployment.
- Pod không được tạo vì quota: xem Used/Hard bằng kubectl describe resourcequota.
- API trả 503: kiểm tra Pod PostgreSQL/Redis, Secret và NetworkPolicy; xem log của Deployment API.
- Service không phân giải được: kiểm tra CoreDNS trong kube-system và policy cho phép DNS.
- Pod không Ready: dùng kubectl describe pod và kubectl logs để xem nguyên nhân.

Đưa thay đổi lên nhánh feature, commit theo từng phần và mở Pull Request để nhóm review.
