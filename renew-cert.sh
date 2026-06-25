#!/usr/bin/env bash
set -euo pipefail

# Daily Let's Encrypt renewal check for <PBX_FQDN> (Cloudflare DNS-01).
# certbot renews only when inside the renew_before_expiry window (45 days),
# then gracefully reloads Apache inside the freepbx container.
cd "$(dirname "$(readlink -f "$0")")"

sudo docker compose exec -T freepbx \
    certbot renew --quiet \
    --deploy-hook "apachectl -k graceful"
