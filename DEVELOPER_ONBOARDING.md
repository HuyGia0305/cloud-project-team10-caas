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

Ba node phải ở trạng thái Ready. PostgreSQL dùng StorageClass local-path.

## 2. Namespace và giới hạn tài nguyên

Tạo ba namespace nếu chúng chưa có:

    kubectl create namespace team-dev-a
    kubectl create namespace team-dev-b
    kubectl create namespace team-shared

Áp dụng LimitRange và ResourceQuota:

    kubectl apply -f limitrange-team-a.yaml
    kubectl apply -f limitrange-team-b.yaml
    kubectl apply -f resourcequota-team-a.yaml
    kubectl apply -f resourcequota-team-b.yaml

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

## 3. Secret cho PostgreSQL

Chạy phần này bằng PowerShell trên cụm mới. Ba namespace phải dùng cùng mật khẩu:

    $dbPassword = [guid]::NewGuid().ToString('N')
    kubectl -n team-shared create secret generic shared-postgres-auth --from-literal="POSTGRES_PASSWORD=$dbPassword"
    kubectl -n team-dev-a create secret generic shared-postgres-auth --from-literal="POSTGRES_PASSWORD=$dbPassword"
    kubectl -n team-dev-b create secret generic shared-postgres-auth --from-literal="POSTGRES_PASSWORD=$dbPassword"
    Remove-Variable dbPassword

Nếu Secret đã tồn tại, bỏ qua bước tạo. Không đổi mật khẩu khi PVC PostgreSQL đang chứa dữ liệu. Không đưa mật khẩu vào Git.

## 4. PostgreSQL và Redis dùng chung

    kubectl apply -f manifests/apps/team-shared.yaml
    kubectl -n team-shared rollout status deployment/shared-postgres --timeout=180s
    kubectl -n team-shared rollout status deployment/shared-redis --timeout=180s
    kubectl -n team-shared get pods,svc,pvc

PVC shared-postgres-data phải ở trạng thái Bound. Kiểm tra hai dịch vụ:

    kubectl -n team-shared exec deployment/shared-postgres -- pg_isready -U caas -d caas
    kubectl -n team-shared exec deployment/shared-redis -- redis-cli ping

PostgreSQL trả về accepting connections; Redis trả về PONG.

## 5. API Team A và Team B

Hai API đều viết bằng Python. Chúng được build thành image riêng và lấy mật khẩu PostgreSQL từ Secret của namespace tương ứng.

    docker build -t caas-team-a-api:v1 apps/team-a
    docker build -t caas-team-b-api:v1 apps/team-b
    k3d image import caas-team-a-api:v1 --cluster caas-phat-lab
    k3d image import caas-team-b-api:v1 --cluster caas-phat-lab
    kubectl apply -f manifests/apps/team-a.yaml
    kubectl apply -f manifests/apps/team-b.yaml
    kubectl -n team-dev-a rollout status deployment/team-a-api --timeout=180s
    kubectl -n team-dev-b rollout status deployment/team-b-api --timeout=180s

Import image trước khi áp dụng manifest vì hai Deployment đặt imagePullPolicy: Never. Tạo lại cụm thì phải import lại image.

## 6. Nginx và HTTPBin

    kubectl apply -f manifests/apps/nginx-team-a.yaml
    kubectl apply -f manifests/apps/httpbin-team-b.yaml
    kubectl -n team-dev-a rollout status deployment/nginx-a --timeout=180s
    kubectl -n team-dev-b rollout status deployment/httpbin-b --timeout=180s

Nginx ở team-dev-a; HTTPBin ở team-dev-b. Cả hai có Service cổng 8080.

## 7. NetworkPolicy

Áp dụng chính sách cho phép trước, sau đó bật chặn mặc định:

    kubectl apply -f networkpolicy-team-a.yaml
    kubectl apply -f networkpolicy-team-b.yaml
    kubectl apply -f network-policy-allow-shared.yaml
    kubectl apply -f network-policy-deny-all.yaml
    kubectl get networkpolicy -A

Pod cùng team được kết nối với nhau. HTTP/TCP giữa Team A và Team B bị chặn. Hai team được dùng DNS và truy cập PostgreSQL cổng 5432, Redis cổng 6379 trong team-shared. Không dùng ping làm phép thử kết luận vì Kubernetes NetworkPolicy không bảo đảm chặn ICMP.

## 8. Kiểm thử

Gọi từng API. Trường postgres phải bằng 1; redis_visits là bộ đếm tăng sau mỗi lần gọi:

    kubectl -n team-dev-a exec deployment/team-a-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/', timeout=5).read().decode())"
    kubectl -n team-dev-b exec deployment/team-b-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/', timeout=5).read().decode())"

Gọi Nginx và HTTPBin qua Service; cả hai trả mã 200:

    kubectl -n team-dev-a exec deployment/team-a-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://nginx-a:8080/', timeout=5).status)"
    kubectl -n team-dev-b exec deployment/team-b-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://httpbin-b:8080/get', timeout=5).status)"

Thử kết nối chéo. Cả hai lệnh phải in ra số khác 0:

    kubectl -n team-dev-a exec deployment/team-a-api -- python -c "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('team-b-api.team-dev-b.svc.cluster.local', 8080)))"
    kubectl -n team-dev-b exec deployment/team-b-api -- python -c "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('team-a-api.team-dev-a.svc.cluster.local', 8080)))"

Thử LimitRange mặc định:

    kubectl apply -f examples/limitrange-default.yaml
    kubectl -n team-dev-a get pod limitrange-default -o jsonpath="{.spec.containers[0].resources}"

Pod phải có requests 100m/128Mi và limits 250m/256Mi. Hai manifest sau phải bị từ chối với lỗi Forbidden:

    kubectl apply -f examples/limitrange-too-large.yaml
    kubectl apply -f examples/quota-cpu-exceeded.yaml

Sau khi thử xong, xóa Pod thử để trả lại quota:

    kubectl -n team-dev-a delete pod limitrange-default

## 9. Xem ứng dụng trên máy cá nhân

Chạy một lệnh port-forward trong terminal riêng. Mở URL ở cột bên phải; nhấn Ctrl+C để dừng.

| Ứng dụng | Lệnh | URL |
|---|---|---|
| API Team A | kubectl -n team-dev-a port-forward svc/team-a-api 8080:8080 | http://localhost:8080/ |
| API Team B | kubectl -n team-dev-b port-forward svc/team-b-api 8081:8080 | http://localhost:8081/ |
| Nginx Team A | kubectl -n team-dev-a port-forward svc/nginx-a 8082:8080 | http://localhost:8082/ |
| HTTPBin Team B | kubectl -n team-dev-b port-forward svc/httpbin-b 8083:8080 | http://localhost:8083/get |

## 10. Địa chỉ Service cho giám sát

| Dịch vụ | Địa chỉ trong cụm |
|---|---|
| API Team A | team-a-api.team-dev-a.svc.cluster.local:8080 |
| API Team B | team-b-api.team-dev-b.svc.cluster.local:8080 |
| Nginx Team A | nginx-a.team-dev-a.svc.cluster.local:8080 |
| HTTPBin Team B | httpbin-b.team-dev-b.svc.cluster.local:8080 |
| PostgreSQL | shared-postgres.team-shared.svc.cluster.local:5432 |
| Redis | shared-redis.team-shared.svc.cluster.local:6379 |

## 11. Khi gặp lỗi

- ErrImageNeverPull ở API: kiểm tra image bằng docker image ls, import lại bằng k3d image import, rồi chạy kubectl rollout restart cho Deployment.
- Pod không được tạo vì quota: xem Used/Hard bằng kubectl describe resourcequota.
- API trả 503: kiểm tra Pod PostgreSQL/Redis, Secret và NetworkPolicy; xem log của Deployment API.
- Service không phân giải được: kiểm tra CoreDNS trong kube-system và policy cho phép DNS.
- Pod không Ready: dùng kubectl describe pod và kubectl logs để xem nguyên nhân.

Đưa thay đổi lên nhánh feature, commit theo từng phần và mở Pull Request để nhóm review.
