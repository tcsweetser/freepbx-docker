-- Main number (0735691900) queue: members + no-answer voicemail.
--
-- Why this file exists:
--   Inbound calls to 0735691900 have no DID route of their own, so they hit the
--   catch-all inbound route "MAIN" -> queue 100. The queue was created with no
--   members, joinempty=yes and no max-wait, so callers were answered into hold
--   music and nothing rang (seen 2026-10-11/12: CDR "ANSWERED" in ext-queues,
--   `queue show 100` -> "No Members"). Queue config is FreePBX application state
--   in the MariaDB `asterisk` database (db named volume), so it is lost on
--   `docker compose down -v` and must be re-applied after a rebuild.
--
-- What it does:
--   1. Adds 905 (TERRY) and 906 (HELEN) as static members of queue 100.
--      Strategy is already ringall, so both phones ring together.
--   2. Sets max-wait to 30s and the failover destination to voicemail box 900
--      (unavailable greeting), so unanswered callers can leave a message.
--
-- Prerequisite: virtual extension 900 "MAIN" with voicemail must exist, or the
-- failover points at nothing. It spans the users table, astdb and voicemail.conf,
-- so create it with bulk import rather than SQL. Pick a 4-digit PIN; do not
-- commit it. `--replace` is required: without it FreePBX 17 bulkimport dies with
-- "Undefined variable $replace".
--   printf 'extension,name,tech,voicemail_enable,voicemail,voicemail_vmpwd\n900,MAIN,virtual,yes,default,<PIN>\n' \
--     | sudo docker compose exec -T freepbx sh -c 'cat > /tmp/v.csv && fwconsole bi --type=extensions --replace /tmp/v.csv; rm -f /tmp/v.csv'
--
-- Apply (from the repo root), then reload FreePBX so Asterisk regenerates config:
--   PW=$(cat mysql_root_password.txt)
--   sudo docker compose exec -T db sh -c "mysql -uroot -p'$PW' asterisk" < config/sql/main-queue.sql
--   sudo docker compose exec -T freepbx fwconsole reload
--
-- Verify: `asterisk -rx "queue show 100"` lists both members.
--
-- Idempotent: INSERT IGNORE on the (id,keyword,data) primary key; UPDATE re-sets.

INSERT IGNORE INTO queues_details (id, keyword, data, flags) VALUES
  ('100', 'member', 'Local/905@from-queue/n,0', 0),
  ('100', 'member', 'Local/906@from-queue/n,0', 1);

UPDATE queues_config
   SET maxwait = '30',
       dest    = 'ext-local,vmu900,1'
 WHERE extension = '100';
