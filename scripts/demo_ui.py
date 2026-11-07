#!/usr/bin/env python3
"""demo_ui.py - Giao dien web cho buoi demo CaaS Nhom 10 (chi dung thu vien chuan cua Python).

Chay (trong thu muc goc repo):   python scripts\\demo_ui.py        (hoac: py scripts\\demo_ui.py)
Trinh duyet tu mo http://localhost:8765. Bam nut de chay tung buoc hoac "Chay tat ca".
Trang chi nghe tren 127.0.0.1 va chi chay cac buoc co san ben duoi (khong chay lenh tuy y).
"""
import atexit, base64, json, os, shutil, subprocess, sys, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8765
KUBECTL = shutil.which("kubectl") or "kubectl"
SA_A = "system:serviceaccount:team-dev-a:dev-user-a"
SA_B = "system:serviceaccount:team-dev-b:dev-user-b"


def run(args, timeout=60):
    try:
        p = subprocess.run([KUBECTL] + args, cwd=ROOT, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout)
        return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()
    except Exception as e:  # noqa
        return 99, str(e)


def py_exec(ns, deploy, code, timeout=60):
    b64 = base64.b64encode(code.encode()).decode()
    one = "import base64;exec(base64.b64decode('%s').decode())" % b64
    return run(["-n", ns, "exec", "deployment/" + deploy, "--", "python", "-c", one], timeout)


def R(name, ok, detail="", cmd=""):
    return {"name": name, "ok": ok, "detail": detail, "cmd": cmd}


# ---------------- cac buoc ----------------
def step_cluster():
    rc, out = run(["get", "nodes", "-o", "wide"])
    ready = sum(1 for l in out.splitlines() if " Ready" in l)
    r1 = R("Cụm có 3 node Ready (1 server + 2 agent)", ready == 3, out, "kubectl get nodes -o wide")
    rc, out = run(["get", "ns"])
    want = ["team-dev-a", "team-dev-b", "team-dev-c", "team-shared", "kyverno", "monitoring"]
    miss = [n for n in want if n not in out]
    return [r1, R("Có đủ namespace nhóm, dùng chung, Kyverno, giám sát", not miss,
                  out if not miss else "Thiếu: " + ", ".join(miss), "kubectl get ns")]


def step_quota():
    rc, q = run(["get", "resourcequota", "-A"])
    rc2, lr = run(["get", "limitrange", "-A"])
    ns = ["team-dev-a", "team-dev-b", "team-dev-c"]
    return [R("Mỗi nhóm có ResourceQuota team-quota", all(n in q for n in ns), q, "kubectl get resourcequota -A"),
            R("Mỗi nhóm có LimitRange container-limits", all(n in lr for n in ns), lr, "kubectl get limitrange -A")]


def can(name, verb, res, sa, ns, expect):
    cmd = "kubectl auth can-i %s %s --as=%s -n %s" % (verb, res, sa, ns)
    rc, out = run(["auth", "can-i", verb, res, "--as=" + sa, "-n", ns])
    got = out.strip().splitlines()[-1].strip() if out.strip() else ""
    return R(name, (got == "yes") == expect, "Kết quả: %s (kỳ vọng: %s)" % (got, "yes" if expect else "no"), cmd)


def step_rbac():
    return [can("Team A tạo được Deployment", "create", "deployments.apps", SA_A, "team-dev-a", True),
            can("Team A KHÔNG tạo được Pod trần", "create", "pods", SA_A, "team-dev-a", False),
            can("Team A KHÔNG đọc được Secret của Team B", "get", "secrets", SA_A, "team-dev-b", False),
            can("Team B KHÔNG xóa được Service", "delete", "services", SA_B, "team-dev-b", False)]


def rejected(name, f):
    rc, out = run(["apply", "-f", f])
    if rc == 0:
        run(["delete", "-f", f, "--ignore-not-found"])
    lines = [l for l in out.splitlines() if l.strip()][:5]
    return R(name, rc != 0, "\n".join(lines) if rc != 0 else "KHÔNG bị từ chối (bất thường)\n" + out, "kubectl apply -f " + f.replace("/", "\\"))


def step_admission():
    return [rejected("Image tag latest bị từ chối", "examples/admission-latest.yaml"),
            rejected("Registry lạ (quay.io) bị từ chối", "examples/admission-untrusted-registry.yaml"),
            rejected("Container chạy root bị từ chối", "examples/admission-root.yaml"),
            rejected("Vượt quota CPU bị từ chối", "examples/quota-cpu-exceeded.yaml"),
            rejected("Vượt LimitRange bị từ chối", "examples/limitrange-too-large.yaml")]


def step_limitrange():
    f = "examples/limitrange-default.yaml"
    rc, out = run(["apply", "-f", f])
    time.sleep(3)
    rc2, res = run(["-n", "team-dev-a", "get", "pod", "limitrange-default", "-o", "jsonpath={.spec.containers[0].resources}"])
    run(["delete", "-f", f, "--ignore-not-found"])
    ok = '"cpu":"250m"' in res and '"memory":"256Mi"' in res and '"cpu":"100m"' in res and '"memory":"128Mi"' in res
    return [R("Pod không khai báo tài nguyên được gán mặc định 100m/128Mi và 250m/256Mi", ok, res, "kubectl apply -f examples\\limitrange-default.yaml")]


def port(name, ns, deploy, host, p, should):
    code = "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('%s',%d)))" % (host, p)
    rc, out = py_exec(ns, deploy, code)
    last = out.strip().splitlines()[-1].strip() if out.strip() else out
    ok = (last == "0") == should
    return R(name, ok, "connect_ex = %s  (0 = kết nối được, 111 = bị từ chối)" % last, "kubectl -n %s exec deployment/%s -- python -c ... connect_ex(('%s',%d))" % (ns, deploy, host, p))


def step_network():
    A = "team-a-api"
    return [port("Team A → PostgreSQL dùng chung :5432 (được phép)", "team-dev-a", A, "shared-postgres.team-shared.svc.cluster.local", 5432, True),
            port("Team A → Redis dùng chung :6379 (được phép)", "team-dev-a", A, "shared-redis.team-shared.svc.cluster.local", 6379, True),
            port("Team A → API Team B :8080 (bị chặn)", "team-dev-a", A, "team-b-api.team-dev-b.svc.cluster.local", 8080, False),
            port("Team B → API Team A :8080 (bị chặn)", "team-dev-b", "team-b-api", "team-a-api.team-dev-a.svc.cluster.local", 8080, False),
            port("Team A → nginx Team C :8080 (bị chặn)", "team-dev-a", A, "team-c-web.team-dev-c.svc.cluster.local", 8080, False)]


DB_CODE = """import os,psycopg
try:
    c=psycopg.connect(host=os.environ['POSTGRES_HOST'],dbname='%s',user=os.environ['POSTGRES_USER'],password=os.environ['POSTGRES_PASSWORD'],connect_timeout=3)
    c.close(); print('KET NOI DUOC (bat thuong)')
except psycopg.OperationalError as e:
    print('DENIED' if 'permission denied' in str(e).lower() else 'LOI: '+str(e))"""


def step_data():
    out = []
    for ns, dep, other, label in [("team-dev-a", "team-a-api", "caas_team_b", "Team A không vào được database của Team B"),
                                  ("team-dev-b", "team-b-api", "caas_team_a", "Team B không vào được database của Team A")]:
        rc, o = py_exec(ns, dep, DB_CODE % other)
        last = o.strip().splitlines()[-1].strip() if o.strip() else o
        out.append(R(label, last == "DENIED", "Kết quả: %s (DENIED = bị từ chối đúng kỳ vọng)" % last, "psycopg.connect(dbname='%s') trong pod %s" % (other, dep)))
    return out


def step_monitor():
    rc, out = run(["-n", "monitoring", "get", "pods"])
    rows = [l for l in out.splitlines()[1:] if "grafana" in l or "prometheus" in l]
    ok = bool(rows) and all("Running" in l for l in rows)
    return [R("Prometheus và Grafana đang chạy", ok, "\n".join(rows) or out, "kubectl -n monitoring get pods"),
            R("Mở Grafana và các trang web bên dưới bằng nút \"Mở\" ở khu vực Trang web", None, "Bấm nút Mở Grafana, rồi chọn Dashboards → Kubernetes / Compute Resources / Namespace (Pods) → team-dev-a")]


STEPS = [
    ("Cụm Kubernetes", "Toàn bộ chạy cục bộ trên Docker, chi phí đám mây 0 đồng.", step_cluster),
    ("Quota và LimitRange", "Mỗi nhóm tối đa 1 CPU/1Gi requests, 2 CPU/2Gi limits, 6 Pod.", step_quota),
    ("RBAC tối thiểu", "Mỗi nhóm chỉ quản lý Deployment trong namespace của mình, không đọc Secret nhóm khác.", step_rbac),
    ("Admission từ chối yêu cầu sai", "PASS ở đây nghĩa là yêu cầu xấu BỊ TỪ CHỐI: cơ chế bảo vệ hoạt động đúng.", step_admission),
    ("LimitRange gán giá trị mặc định", "Pod quên khai báo tài nguyên vẫn được gán mức an toàn.", step_limitrange),
    ("NetworkPolicy mặc định từ chối", "0 là kết nối được, 111 là bị từ chối. Chỉ mở luồng cần thiết.", step_network),
    ("Cô lập dữ liệu", "Mỗi nhóm có database, role PostgreSQL và Redis ACL riêng.", step_data),
    ("Giám sát Prometheus / Grafana", "Dashboard CPU, RAM và quota theo từng namespace.", step_monitor),
]

# ---------------- port-forward ----------------
PF = {}


def stop_all():
    for p in PF.values():
        try: p.terminate()
        except Exception: pass


atexit.register(stop_all)


def port_open(p):
    import socket
    try:
        with socket.create_connection(("127.0.0.1", p), timeout=1):
            return True
    except OSError:
        return False


def start_pf(name):
    """Tra ve (ok, thong bao). Neu cong da mo san (vd. port-forward cu) thi coi nhu san sang."""
    if name == "grafana":
        rc, out = run(["-n", "monitoring", "get", "svc", "-o", "name"])
        svc = next((l.strip() for l in out.splitlines() if "grafana" in l), "service/monitoring-grafana")
        args, lport = ["-n", "monitoring", "port-forward", svc, "3000:80"], 3000
    elif name == "team-a":
        args, lport = ["-n", "team-dev-a", "port-forward", "svc/team-a-api", "8080:8080"], 8080
    elif name == "team-b":
        args, lport = ["-n", "team-dev-b", "port-forward", "svc/team-b-api", "8081:8080"], 8081
    else:
        return False, "không rõ"
    if port_open(lport):
        return True, "cổng %d đã mở sẵn" % lport
    try:
        import tempfile
        errf = tempfile.TemporaryFile()
        PF[name] = subprocess.Popen([KUBECTL] + args, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=errf)
    except Exception as e:  # noqa
        return False, str(e)
    for _ in range(20):
        time.sleep(0.5)
        if port_open(lport):
            return True, "đang chạy"
        if PF[name].poll() is not None:
            break
    err = ""
    if PF[name].poll() is not None:
        try:
            errf.seek(0)
            err = errf.read().decode("utf-8", "replace").strip()
        except Exception:
            pass
    else:
        PF[name].terminate()
    return False, "kubectl port-forward không mở được cổng %d. %s" % (lport, err or "Hết thời gian chờ, kiểm tra Pod/Service có đang chạy không.")


def grafana_pw():
    rc, out = run(["-n", "monitoring", "get", "secret", "grafana-admin", "-o", "jsonpath={.data.admin-password}"])
    try:
        return base64.b64decode(out).decode()
    except Exception:
        return ""


# ---------------- web ----------------
PAGE = r"""<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Demo CaaS Nhóm 10</title><style>
:root{--teal:#15848b;--teal-d:#0e5f63;--tint:#eaf5f5;--ink:#1f2a33;--soft:#4a5863;--line:#c9dddf;--ok:#1f8a4c;--bad:#c02a2a;--bg:#f6f9f9;--card:#fff}
@media(prefers-color-scheme:dark){:root{--ink:#e8eef0;--soft:#9fb0b8;--line:#2c4a4d;--bg:#0f1a1c;--card:#16262a;--tint:#173236}}
*{box-sizing:border-box}body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:var(--bg);color:var(--ink)}
header{background:var(--teal-d);color:#fff;padding:18px 28px;display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between}
header h1{margin:0;font-size:22px}header p{margin:2px 0 0;opacity:.85;font-size:14px}
main{max-width:1100px;margin:0 auto;padding:20px 16px 60px}
button{font:inherit;cursor:pointer;border-radius:8px;border:1px solid var(--teal);background:var(--teal);color:#fff;padding:8px 16px}
button.ghost{background:transparent;color:var(--teal)}header button{background:#fff;color:var(--teal-d);border-color:#fff;font-weight:600}
button:disabled{opacity:.5;cursor:wait}
.score{display:flex;gap:16px;margin:0 0 16px;font-weight:600}.pill{padding:6px 14px;border-radius:20px;background:var(--tint)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;margin:0 0 14px;overflow:hidden}
.ch{display:flex;gap:12px;align-items:center;padding:14px 16px;border-bottom:1px solid var(--line)}
.num{width:32px;height:32px;border-radius:50%;background:var(--teal);color:#fff;display:grid;place-items:center;font-weight:700;flex:none}
.ct{flex:1}.ct b{font-size:17px}.ct small{display:block;color:var(--soft);margin-top:2px}
.res{padding:10px 16px;border-bottom:1px solid var(--line)}.res:last-child{border:0}
.row{display:flex;gap:10px;align-items:flex-start}.badge{font-size:12px;font-weight:700;padding:3px 9px;border-radius:5px;color:#fff;flex:none;margin-top:2px}
.pass{background:var(--ok)}.fail{background:var(--bad)}.info{background:var(--soft)}
details{margin:6px 0 0 0}summary{cursor:pointer;color:var(--soft);font-size:13px}
pre{margin:6px 0 0;padding:10px;background:#0f1a1c;color:#d7e7ea;border-radius:8px;font:12px Consolas,monospace;white-space:pre-wrap;word-break:break-word;max-height:260px;overflow:auto}
code{font:12px Consolas,monospace;color:var(--soft)}.empty{padding:12px 16px;color:var(--soft);font-size:14px}
.links{display:flex;flex-wrap:wrap;gap:10px;padding:14px 16px}.links a{color:var(--teal)}
</style></head><body>
<header><div><h1>Demo nền tảng CaaS – Nhóm 10</h1><p>Quota, RBAC, NetworkPolicy, Admission, cô lập dữ liệu, giám sát</p></div>
<button id="all">▶ Chạy tất cả</button></header>
<main><div class="score"><span class="pill" id="sp">PASS: 0</span><span class="pill" id="sf">FAIL: 0</span></div>
<div id="steps"></div>
<div class="card"><div class="ch"><div class="num">★</div><div class="ct"><b>Trang web để mở khi demo</b><small>Mỗi nút bật kubectl port-forward trong nền; tự tắt khi đóng chương trình.</small></div></div>
<div class="links"><button class="ghost" onclick="pf('grafana','http://localhost:3000')">Mở Grafana</button>
<button class="ghost" onclick="pf('team-a','http://localhost:8080')">Mở API Team A</button>
<button class="ghost" onclick="pf('team-b','http://localhost:8081')">Mở API Team B</button>
<span id="pw" class="empty"></span></div></div></main>
<script>
const E=s=>s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
let P=0,F=0;const done={};
function score(){document.getElementById('sp').textContent='PASS: '+P;document.getElementById('sf').textContent='FAIL: '+F}
async function load(){const d=await (await fetch('/steps')).json();const box=document.getElementById('steps');
d.forEach((s,i)=>{const el=document.createElement('div');el.className='card';el.innerHTML=
`<div class="ch"><div class="num">${i}</div><div class="ct"><b>${E(s.title)}</b><small>Nói với thầy: ${E(s.say)}</small></div><button id="b${i}" onclick="runStep(${i})">Chạy</button></div><div id="r${i}" class="empty">Chưa chạy.</div>`;box.appendChild(el)})}
async function runStep(i){const b=document.getElementById('b'+i),r=document.getElementById('r'+i);b.disabled=true;b.textContent='Đang chạy...';r.className='empty';r.textContent='Đang chạy, vui lòng đợi...';
if(done[i]){P-=done[i].p;F-=done[i].f}
try{const d=await (await fetch('/run?step='+i)).json();let p=0,f=0;r.className='';r.innerHTML=d.map(x=>{const c=x.ok===null?'info':(x.ok?'pass':'fail');if(x.ok===true)p++;if(x.ok===false)f++;
return `<div class="res"><div class="row"><span class="badge ${c}">${x.ok===null?'INFO':(x.ok?'PASS':'FAIL')}</span><div><div>${E(x.name)}</div>${x.cmd?`<code>${E(x.cmd)}</code>`:''}</div></div>${x.detail?`<details ${x.ok===false?'open':''}><summary>Chi tiết kết quả</summary><pre>${E(x.detail)}</pre></details>`:''}</div>`}).join('');
done[i]={p,f};P+=p;F+=f;score()}catch(e){r.textContent='Lỗi: '+e}
b.disabled=false;b.textContent='Chạy lại'}
document.getElementById('all').onclick=async function(){this.disabled=true;P=0;F=0;for(const k in done)delete done[k];score();
const n=document.querySelectorAll('[id^=b]').length-0;for(let i=0;i<8;i++){if(document.getElementById('b'+i))await runStep(i)}this.disabled=false;this.textContent='▶ Chạy lại tất cả'};
async function pf(n,u){const d=await (await fetch('/pf?name='+n)).json();if(d.ok){if(n==='grafana'){const w=await (await fetch('/pw')).json();document.getElementById('pw').textContent='Grafana: tài khoản admin / mật khẩu '+w.pw}window.open(u,'_blank')}else alert('Không mở được: '+d.msg)}
load();score();
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, body, ctype="application/json; charset=utf-8", code=200):
        b = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/":
            return self.send(PAGE, "text/html; charset=utf-8")
        if u.path == "/steps":
            return self.send(json.dumps([{"title": t, "say": s} for t, s, _ in STEPS]))
        if u.path == "/run":
            try:
                i = int(q.get("step", ["-1"])[0]); res = STEPS[i][2]()
            except Exception as e:  # noqa
                res = [R("Lỗi khi chạy bước", False, str(e))]
            return self.send(json.dumps(res))
        if u.path == "/pf":
            ok, msg = start_pf(q.get("name", [""])[0]); return self.send(json.dumps({"ok": ok, "msg": msg}))
        if u.path == "/pw":
            return self.send(json.dumps({"pw": grafana_pw()}))
        self.send("{}", code=404)


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    url = "http://localhost:%d" % PORT
    print("Giao dien demo: %s   (Ctrl+C de dung)" % url)
    threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_all()
