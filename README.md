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
