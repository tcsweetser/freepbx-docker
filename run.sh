#!/usr/bin/env bash
set -euo pipefail

# FreePBX runs on host networking, so RTP/SIP bind directly to the host
# interfaces (dual-stack). Network address translation is handled elsewhere;
# external IPv4 trunk reachability is configured on the Mikrotik RB5009
# (see docs/mikrotik-rb5009-firewall.md).

# INSTALL FREEPBX
if [[ "$*" == *"--install-freepbx"* ]]; then
    sudo docker compose exec -it -w /usr/local/src/freepbx freepbx \
        php install -n --dbuser=freepbxuser \
        --dbpass="$(cat freepbxuser_password.txt)" --dbhost=127.0.0.1

# CLEAN
elif [[ "$*" == *"--clean-all"* ]]; then
    read -r -p "Are you sure you want to clean up everything? Data will be lost. (yes/no)? " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        echo "Cleanup aborted."
        exit 0
    fi
    sudo docker container stop freepbx-docker-db-1 && sudo docker container rm freepbx-docker-db-1
    sudo docker container stop freepbx-docker-freepbx-1 && sudo docker container rm freepbx-docker-freepbx-1
    sudo docker volume rm freepbx-docker_var_data
    sudo docker volume rm freepbx-docker_etc_data
    sudo docker volume rm freepbx-docker_mysql_data
    sudo docker network rm freepbx-docker_defaultnet

# START
else
    sudo docker compose up -d && {
        printf "Waiting for database readiness"
        for _ in $(seq 1 10); do printf "."; sleep 1; done
        echo " done"
    }
fi
