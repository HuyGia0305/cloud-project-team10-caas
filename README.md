# Đồ Án Điện Toán Đám Mây - UTH (2026 - 2027)
## Đề Tài 10: Xây dựng nền tảng CaaS nhỏ cho nhiều nhóm phát triển với quota và cô lập tài nguyên

* **Giảng viên hướng dẫn:** TS. Lê Quốc Tuấn
* **Nhóm sinh viên thực hiện (Nhóm 10):**
  1. Nguyễn Gia Huy ( Hạ tầng k3d, RBAC, Kyverno Policy Engine)
  2. Huỳnh Tấn Phát (Quản lý tài nguyên ResourceQuota, LimitRange, NetworkPolicy)
  3. Đinh Văn Thái (Giám sát Prometheus/Grafana, Kiểm thử chịu tải, Báo cáo kỹ thuật)

### Kiến trúc nền tảng:
- Cụm Kubernetes Multi-Node chạy trên k3d (1 Server, 2 Agents).
- Phân vùng đa người dùng (Multi-tenancy) với 3 Namespace: \	eam-dev-a\, \	eam-dev-b\, \	eam-shared\.
- Phân quyền truy cập theo vai trò (RBAC).
- Kiểm soát tuân thủ và chính sách an toàn (Kyverno Admission Controller).
