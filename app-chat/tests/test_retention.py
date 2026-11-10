"""Proves the two storage rules are enforced by the database itself.

Run against a throwaway database:
    DATABASE_URL=postgresql://... SESSION_SECRET=$(python -c 'print("x"*32)') pytest -q
"""
import os

import psycopg
import pytest

from app import migrate

DB = os.environ["DATABASE_URL"]


@pytest.fixture()
def conn():
    with psycopg.connect(DB, autocommit=True) as c:
        c.execute("DROP TABLE IF EXISTS chats, users CASCADE")
        assert migrate.main() == 0
        yield c


def test_51st_user_replaces_the_first_user_and_their_chats(conn):
    for i in range(50):
        conn.execute("INSERT INTO users (id, created_at) VALUES (%s, now() - make_interval(mins => %s))",
                     (f"u{i}", 100 - i))   # u0 is the oldest
    conn.execute("INSERT INTO chats (user_id, prompt, reply) VALUES ('u0', 'hi', 'hello')")
    conn.execute("INSERT INTO users (id) VALUES ('u50')")
    ids = {r[0] for r in conn.execute("SELECT id FROM users").fetchall()}
    assert len(ids) == 50 and "u50" in ids and "u0" not in ids and "u1" in ids
    assert conn.execute("SELECT count(*) FROM chats WHERE user_id = 'u0'").fetchone()[0] == 0
    conn.execute("INSERT INTO users (id) VALUES ('u51')")          # next one replaces u1
    ids = {r[0] for r in conn.execute("SELECT id FROM users").fetchall()}
    assert len(ids) == 50 and "u1" not in ids and "u2" in ids


def test_only_last_15_chats_per_user_are_kept(conn):
    conn.execute("INSERT INTO users (id) VALUES ('a'), ('b')")
    for i in range(20):
        conn.execute("INSERT INTO chats (user_id, prompt, reply) VALUES ('a', %s, 'r')", (f"p{i}",))
    conn.execute("INSERT INTO chats (user_id, prompt, reply) VALUES ('b', 'only', 'r')")

    prompts = [r[0] for r in conn.execute(
        "SELECT prompt FROM chats WHERE user_id='a' ORDER BY id").fetchall()]
    assert len(prompts) == 15
    assert prompts[0] == "p5" and prompts[-1] == "p19"  # oldest 5 trimmed
    assert conn.execute("SELECT count(*) FROM chats WHERE user_id='b'").fetchone()[0] == 1


def test_migration_is_idempotent(conn):
    assert migrate.main() == 0
    assert migrate.main() == 0
