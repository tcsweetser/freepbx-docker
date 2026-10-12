-- Minimal Asterisk + FreePBX logging: errors and warnings only.
--
-- Why this file exists:
--   Asterisk's logger channels and FreePBX's log settings are FreePBX application
--   state in the MariaDB `asterisk` database (db named volume), so they revert to
--   the chatty defaults after `docker compose down -v`. Re-apply this after a
--   rebuild.
--
-- What it does:
--   1. Asterisk `full` log and console: error + warning only (debug, notice,
--      verbose off). FreePBX's Log Files module regenerates
--      logger_logfiles_additional.conf from logfile_logfiles on reload.
--   2. FreePBX: stop logging routine output and notifications to freepbx.log,
--      and log PHP errors only.
--   Left as-is on purpose:
--     - AMPSYSLOGLEVEL=FILE: every other value routes to syslog, which this
--       container does not run, so FreePBX errors would be lost entirely.
--     - queue_log and CDR CSV: call records used by reports, not debug logging.
--
-- Temporary debugging (not persisted, resets on restart):
--   asterisk -rx "pjsip set logger on"   # SIP packets into the full log
--   sleep 40 | asterisk -rvvv            # live dialplan trace on a console
--
-- Apply (from the repo root), then reload FreePBX so Asterisk picks it up:
--   PW=$(cat mysql_root_password.txt)
--   sudo docker compose exec -T db sh -c "mysql -uroot -p'$PW' asterisk" < config/sql/logging-minimal.sql
--   sudo docker compose exec -T freepbx fwconsole reload
--
-- Verify: `asterisk -rx "logger show channels"` lists only ERROR WARNING.
--
-- Idempotent: plain UPDATEs.

UPDATE logfile_logfiles
   SET debug = 'off', notice = 'off', verbose = 'off',
       error = 'on',  warning = 'on'
 WHERE name IN ('full', 'console');

UPDATE freepbx_settings SET value = '0' WHERE keyword = 'LOG_OUT_MESSAGES';
UPDATE freepbx_settings SET value = '0' WHERE keyword = 'LOG_NOTIFICATIONS';
UPDATE freepbx_settings SET value = 'ALL_NOSTRICTNOTICEWARNINGDEPRECIATED'
 WHERE keyword = 'PHP_ERROR_LEVEL';
