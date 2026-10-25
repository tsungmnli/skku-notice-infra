-- Run once as a Postgres superuser on the home server. See README.md in this folder.
-- The application role owns its database so Alembic can create and alter tables.
--
-- The password is NOT written here. It is read from the environment variable
-- SKKU_APP_PASSWORD (kept in .env, which git ignores). Requires psql 15 or newer (\getenv).
-- Store the same value in Vault: kv/skku-notice -> DATABASE_URL.

\getenv app_password SKKU_APP_PASSWORD
\if :{?app_password}
\else
  \echo 'ERROR: SKKU_APP_PASSWORD is not set. Copy .env.example to .env, fill it in, and load it (see README.md).'
  \quit
\endif

-- Refuse empty or placeholder passwords.
SELECT (:'app_password' IN ('', 'CHANGE-ME')) AS bad_password \gset
\if :bad_password
  \echo 'ERROR: SKKU_APP_PASSWORD is empty or still CHANGE-ME.'
  \quit
\endif

CREATE ROLE skku_app LOGIN PASSWORD :'app_password';
CREATE DATABASE skkunoti OWNER skku_app ENCODING 'UTF8';

-- Keep other roles (and PUBLIC) out of this database.
REVOKE ALL ON DATABASE skkunoti FROM PUBLIC;
GRANT CONNECT ON DATABASE skkunoti TO skku_app;

-- Optional but recommended: reject runaway queries from the API.
ALTER ROLE skku_app SET statement_timeout = '15s';
