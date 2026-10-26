import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg
import redis


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.respond(200, {"status": "ok"})
            return

        try:
            with psycopg.connect(
                host=os.environ["POSTGRES_HOST"],
                dbname="caas",
                user="caas",
                password=os.environ["POSTGRES_PASSWORD"],
                connect_timeout=3,
            ) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT 1")
                    database_result = cursor.fetchone()[0]

            cache = redis.Redis(
                host=os.environ["REDIS_HOST"],
                port=6379,
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


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()