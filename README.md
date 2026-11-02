# Đồ Án Điện Toán Đám Mây - UTH 
## Đề Tài 10: Xây dựng nền tảng CaaS nhỏ cho nhiều nhóm phát triển với quota và cô lập tài nguyên

* **Giảng viên hướng dẫn:** TS. Lê Quốc Tuấn
* **Nhóm sinh viên thực hiện (Nhóm 10):**
  1. Nguyễn Gia Huy ( Hạ tầng k3d, RBAC, Kyverno Policy Engine)
  2. Huỳnh Tấn Phát (Quản lý tài nguyên ResourceQuota, LimitRange, NetworkPolicy)
  3. Đinh Văn Thái (Giám sát Prometheus/Grafana, Kiểm thử chịu tải, Báo cáo kỹ thuật)

### Kiến trúc nền tảng
- Cụm Kubernetes đa node chạy trên k3d (1 server, 2 agents).
- Ba namespace nhóm (`team-dev-a`, `team-dev-b`, `team-dev-c`) và namespace dùng chung `team-shared`.
- Cô lập tài nguyên bằng ResourceQuota/LimitRange; quyền triển khai riêng bằng ServiceAccount/RBAC.
- Cô lập luồng mạng bằng default-deny NetworkPolicy; admission policy bằng Kyverno và Pod Security Admission.
- Prometheus/Grafana qua Helm, dashboard CPU/RAM/quota theo nhóm; API A/B phát metrics.

Xem [hướng dẫn triển khai](DEVELOPER_ONBOARDING.md), [báo cáo và kết quả kiểm thử](REPORT.md), và [script kiểm chứng](scripts/validate-platform.ps1).


### Minh chứng kiểm thử
- evidence/acceptance-test-matrix.csv: ma trận 28 ca kiểm thử được phép / bị từ chối.
- evidence/latency-benchmark.csv: số đo độ trễ API Team B trước và trong lúc tải CPU của Team A (2 lượt, 12 mẫu mỗi lượt; chỉ mang tính tham khảo).
- scripts/validate-platform.ps1: chạy lại toàn bộ kiểm tra trên cụm.

### Phiên bản công nghệ
| Thành phần | Phiên bản |
|---|---|
| Kubernetes (k3s trong k3d) | v1.35.5+k3s1 |
| Kyverno (Helm chart) | 3.9.2 |
| kube-prometheus-stack (Helm chart) | 92.14.0 |
| Docker | Docker version 29.8.2, build 7fc2dff |
| k3d | k3d version v5.9.0 |
| kubectl | Client Version: v1.36.1 |
| Helm | v4.3.1+gc0d08d0 |

### Dọn dẹp tài nguyên và chi phí
Toàn bộ hệ thống chạy cục bộ trên Docker Desktop nên chi phí dịch vụ đám mây là 0 đồng. Tài nguyên máy tiêu tốn đáng kể nhất là Prometheus (giới hạn 1 CPU, 1Gi RAM, xem monitoring/values.yaml) cùng 3 node k3d.

Dừng cụm tạm thời:

    k3d cluster stop caas-team10

Xóa hoàn toàn cụm và giải phóng ổ đĩa:

    k3d cluster delete caas-team10
    docker image prune -f
