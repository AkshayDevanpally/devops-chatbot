"""Apply schema.sql. Runs as a Kubernetes initContainer / compose one-shot, never inside the web process.

An advisory lock makes it safe when several replicas start at once.
"""
import pathlib
import sys
import time

import psycopg

from app.config import DATABASE_URL

SCHEMA = (pathlib.Path(__file__).parent / "schema.sql").read_text(encoding="utf-8")


def main() -> int:
    for attempt in range(1, 31):
        try:
            with psycopg.connect(DATABASE_URL, connect_timeout=5) as conn:
                conn.execute("SELECT pg_advisory_lock(1001)")
                try:
                    conn.execute(SCHEMA)
                    conn.commit()
                finally:
                    conn.execute("SELECT pg_advisory_unlock(1001)")
            print("migration: schema applied")
            return 0
        except psycopg.OperationalError as exc:
            print(f"migration: database not ready (attempt {attempt}/30): {exc.__class__.__name__}")
            time.sleep(2)
    print("migration: giving up")
    return 1


if __name__ == "__main__":
    sys.exit(main())
