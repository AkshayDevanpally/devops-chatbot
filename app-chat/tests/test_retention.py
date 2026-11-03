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


def test_only_first_50_users_are_stored(conn):
    for i in range(50):
        conn.execute("INSERT INTO users (id) VALUES (%s)", (f"u{i}",))
    with pytest.raises(psycopg.errors.RaiseException, match="user_limit_reached"):
        conn.execute("INSERT INTO users (id) VALUES ('u50')")
    assert conn.execute("SELECT count(*) FROM users").fetchone()[0] == 50


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
