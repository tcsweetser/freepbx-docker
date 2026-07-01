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
--
--   1. media_encryption = no  (REQUIRED for calls to work)
--      FreePBX defaulted this trunk to `sdes`, which makes Asterisk demand SRTP
--      (RTP/SAVP + a=crypto). Leaptel offers plain unencrypted media (RTP/AVP), so
--      SDES negotiated to nothing and every call was rejected with
--      `488 Not Acceptable Here` / "Couldn't negotiate stream ... (nothing)". This
--      looked like a codec problem but was purely the encryption mismatch; alaw was
--      always in the allow list. Setting it to `no` lets alaw negotiate over plain
--      RTP, which is standard for an ITSP trunk. Verified: inbound call rings and
--      answers with `RTP/AVP 8` (PCMA/alaw). See memory leaptel-codec-encryption.
--
--   2. Registration retry intervals = 600s
--      Backs the retry intervals off from the noisy FreePBX defaults (30s/30s/60s).
--      The trunk registers successfully now, so on the happy path re-registration
--      follows the registration expiry, not these values; they only govern the
--      retry cadence *after a failed* attempt. 600s keeps failure-retry log noise
--      down. Drop these back toward 30-60s if you want faster recovery after an
--      outage. Inbound calls arrive via the IP `identify` (103.51.112.38/32) and are
--      unaffected by registration state either way.
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

-- 1. Plain RTP: Leaptel offers RTP/AVP, so SDES must be off or calls 488.
UPDATE pjsip
SET data = 'no'
WHERE keyword = 'media_encryption'
  AND id IN (SELECT trunkid FROM trunks WHERE name = 'Leaptel' AND tech = 'pjsip');

-- 2. Quiet the registration failure-retry cadence.
UPDATE pjsip
SET data = '600'
WHERE keyword IN ('retry_interval', 'forbidden_retry_interval', 'fatal_retry_interval')
  AND id IN (SELECT trunkid FROM trunks WHERE name = 'Leaptel' AND tech = 'pjsip');
