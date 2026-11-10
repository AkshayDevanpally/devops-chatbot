-- Idempotent schema. Retention rules live in the database so no code path can bypass them.

CREATE TABLE IF NOT EXISTS users (
    id          TEXT PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chats (
    id          BIGSERIAL PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    prompt      TEXT NOT NULL,
    reply       TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_chats_user_created ON chats (user_id, created_at DESC, id DESC);

-- Rule 1: at most 50 users are stored. A new user beyond that replaces the FIRST user created
-- (first in, first out), whose chats go with them (ON DELETE CASCADE). Chosen on 10 Nov 2026 when the
-- site went public; before, the 51st user was refused and chatted as a guest.
CREATE OR REPLACE FUNCTION cap_users() RETURNS trigger AS $$
BEGIN
    -- Serialise concurrent sign-ups so two inserts can't both see 49 (or both remove the same user).
    PERFORM pg_advisory_xact_lock(424242);
    DELETE FROM users
    WHERE id IN (SELECT id FROM users ORDER BY created_at, id
                 LIMIT GREATEST((SELECT count(*) FROM users) - 49, 0));
    RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS t_cap_users ON users;
CREATE TRIGGER t_cap_users BEFORE INSERT ON users
    FOR EACH ROW EXECUTE FUNCTION cap_users();

-- Rule 2: keep only the newest 15 chats per user.
CREATE OR REPLACE FUNCTION trim_chats() RETURNS trigger AS $$
BEGIN
    DELETE FROM chats
    WHERE user_id = NEW.user_id
      AND id NOT IN (
          SELECT id FROM chats
          WHERE user_id = NEW.user_id
          ORDER BY created_at DESC, id DESC
          LIMIT 15
      );
    RETURN NULL;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS t_trim_chats ON chats;
CREATE TRIGGER t_trim_chats AFTER INSERT ON chats
    FOR EACH ROW EXECUTE FUNCTION trim_chats();
