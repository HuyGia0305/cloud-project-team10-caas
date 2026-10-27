import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
import redis
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest

REQUESTS = Counter(
    "caas_http_requests_total",
    "HTTP requests served by the CaaS sample APIs",
    ["team", "method", "path", "status"],
)

class Handler(BaseHTTPRequestHandler):
    def respond(self, status, data):
        path = self.path if self.path in ("/", "/health") else "/other"
        REQUESTS.labels("b", self.command, path, str(status)).inc()
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/metrics":
            body = generate_latest()
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/health":
            self.respond(200, {"status": "ok"})
            return

        try:
            with psycopg.connect(
                host=os.environ["POSTGRES_HOST"],
                dbname=os.environ["POSTGRES_DB"],
                user=os.environ["POSTGRES_USER"],
                password=os.environ["POSTGRES_PASSWORD"],
                connect_timeout=3,
            ) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT 1")
                    database_result = cursor.fetchone()[0]

            cache = redis.Redis(
                host=os.environ["REDIS_HOST"],
                port=6379,
                username=os.environ["REDIS_USER"],
                password=os.environ["REDIS_PASSWORD"],
                socket_connect_timeout=3,
                socket_timeout=3,
            )
            visits = cache.incr("team-b-visits")
            self.respond(200, {
                "team": "B",
                "postgres": database_result,
                "redis_visits": visits,
            })
        except Exception as error:
            self.respond(503, {"error": type(error).__name__})


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()