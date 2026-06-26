-- Leaptel trunk: post-creation tweaks that are NOT reproducible from repo build.
--
-- Why this file exists:
--   The Leaptel trunk is FreePBX application state stored in the MariaDB `asterisk`
--   database (db named volume), created via the FreePBX GUI. `docker compose down -v`
--   wipes that volume, so the trunk and these values must be re-applied after a
--   rebuild + trunk recreation. This snippet captures the non-default values so the
--   re-apply is exact and auditable instead of remembered.
--
-- What it does:
--   Backs the registration retry intervals off from the noisy defaults
--   (30s/30s/60s) to 600s. Reason: the upstream Leaptel registration is currently
--   rejected (provider-side credential issue, see memory leaptel-trunk-403), and
--   the fast retries spam the Asterisk log with 401/403 every ~30-60s. 600s keeps
--   the trunk trying without the noise. Inbound calls are unaffected: they arrive
--   via the IP `identify` (103.51.112.38/32), not via this registration.
--
-- Keyed on the trunk NAME, not its numeric id, so it survives a different trunkid
-- being assigned when the trunk is recreated.
--
-- Apply (from the repo root), then reload FreePBX so Asterisk regenerates config:
--   PW=$(cat mysql_root_password.txt)
--   sudo docker compose exec -T db sh -c "mysql -uroot -p'$PW' asterisk" < config/sql/leaptel-trunk-tweaks.sql
--   sudo docker compose exec -T freepbx fwconsole reload
--
-- Idempotent: re-running it just re-sets the same values.

UPDATE pjsip
SET data = '600'
WHERE keyword IN ('retry_interval', 'forbidden_retry_interval', 'fatal_retry_interval')
  AND id IN (SELECT trunkid FROM trunks WHERE name = 'Leaptel' AND tech = 'pjsip');
