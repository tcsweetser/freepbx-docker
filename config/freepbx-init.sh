#!/usr/bin/env bash
#
# Idempotent startup customizations for the escomputers/freepbx image.
#
# Why this exists:
#   The freepbx service uses `network_mode: host`, so it competes with host
#   daemons for ports. On this host exim4 owns :25 and nginx owns :80/:443.
#   The stock image starts postfix (binds :25) and apache (binds :80/:443)
#   under `set -e`, so those clashes made the container exit 1 and restart-loop.
#
#   These tweaks normally live in the etc_data volume, which means they are lost
#   on `docker compose down -v`. Running them here on every boot makes them
#   reproducible: a fresh volume self-heals. Every step is idempotent.
#
# This script is mounted into the container and runs BEFORE the image's real
# entrypoint, which it execs at the end via "$@".

set -euo pipefail

echo "[freepbx-init] applying reproducible customizations"

# --- Postfix: send-only relay -------------------------------------------------
# Disable the inbound smtpd listener so postfix never tries to bind :25
# (host exim4 owns it). FreePBX only needs to SEND mail via the Gmail relay.
# Also send logs to stdout so they show up in `docker compose logs` (the image
# has no running syslog daemon).
postconf -e 'master_service_disable = smtp.inet'
postconf -e 'maillog_file = /dev/stdout'

# --- Apache: move off host-occupied :80/:443 to :8082/:8443 -------------------
ports_conf=/etc/apache2/ports.conf
sed -i -E 's/^Listen 80$/Listen 8082/'              "$ports_conf"
sed -i -E 's/^([[:space:]]*)Listen 443$/\1Listen 8443/' "$ports_conf"
sed -i -E 's/<VirtualHost \*:80>/<VirtualHost *:8082>/'  /etc/apache2/sites-available/000-default.conf
sed -i -E 's/<VirtualHost \*:443>/<VirtualHost *:8443>/' /etc/apache2/sites-available/default-ssl.conf

# Self-signed cert so apache can start TLS today; the Let's Encrypt DNS-01
# rotation replaces it with the real cert paths later.
if [ ! -f /etc/ssl/certs/ssl-cert-snakeoil.pem ]; then
  make-ssl-cert generate-default-snakeoil --force-overwrite
fi

# Enable TLS module and the SSL vhost (both idempotent).
a2enmod  ssl         >/dev/null
a2ensite default-ssl >/dev/null

# --- TLS cert: prefer the Let's Encrypt cert, fall back to snakeoil -----------
# The real cert is issued inside this container with certbot (Cloudflare DNS-01)
# and lives in the etc_data volume at /etc/letsencrypt/live/$PBX_FQDN/. We only
# repoint apache at it WHEN IT EXISTS — otherwise apache would fail to start and
# the container would loop. PBX_FQDN comes from site.env via compose env_file.
ssl_conf=/etc/apache2/sites-available/default-ssl.conf
le_dir="/etc/letsencrypt/live/${PBX_FQDN:-__unset__}"
if [ -f "${le_dir}/fullchain.pem" ] && [ -f "${le_dir}/privkey.pem" ]; then
  sed -i -E "s#^([[:space:]]*SSLCertificateFile[[:space:]]+).*#\1${le_dir}/fullchain.pem#"  "$ssl_conf"
  sed -i -E "s#^([[:space:]]*SSLCertificateKeyFile[[:space:]]+).*#\1${le_dir}/privkey.pem#" "$ssl_conf"
  echo "[freepbx-init] TLS: using Let's Encrypt cert for ${PBX_FQDN}"
else
  echo "[freepbx-init] TLS: no Let's Encrypt cert at ${le_dir}; serving self-signed snakeoil"
fi

# Fail fast if our edits produced an invalid apache config.
apache2ctl configtest

echo "[freepbx-init] done; handing off to image entrypoint"
exec "$@"
