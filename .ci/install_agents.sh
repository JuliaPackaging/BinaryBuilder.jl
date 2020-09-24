#!/bin/bash

set -e

NUM_AGENTS=3
SRC_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
mkdir -p ${HOME}/.config/systemd/user
source .env

# Create a nice little rootfs for our agents
if [[ ! -d "${STORAGE_DIR}/rootfs" ]]; then
    echo "Setting up rootfs..."
    mkdir -p "${STORAGE_DIR}/rootfs"
    sudo debootstrap --variant=minbase --include=curl,expect,locales buster "${STORAGE_DIR}/rootfs"

    # Remove special `dev` files
    sudo rm -rf "${STORAGE_DIR}/rootfs/dev/*"
    # take ownership
    sudo chown $(id -u):$(id -g) -R "${STORAGE_DIR}/rootfs"
    # Remove `_apt` user so that `apt` doesn't try to `setgroups()`
    sed '/_apt:/d' -i "${STORAGE_DIR}/rootfs/etc/passwd"

    # Set up the one true locale
    echo "en_US.UTF-8 UTF-8" >> ${STORAGE_DIR}/rootfs/etc/locale.gen
    sudo chroot ${STORAGE_DIR}/rootfs locale-gen
fi

if [[ ! -f "${STORAGE_DIR}/rootfs/usr/local/bin/julia" ]]; then
    # Install Julia
    echo "Installing Julia..."
    mkdir -p "${STORAGE_DIR}/rootfs/depot"
    JULIA_URL="https://julialangnightlies-s3.julialang.org/bin/linux/x64/julia-latest-linux64.tar.gz"
    curl -# -L "$JULIA_URL" | tar --strip-components=1 -zx -C "${STORAGE_DIR}/rootfs/usr/local"
fi

for AGENT_IDX in $(seq 1 $NUM_AGENTS); do
    if [[ ! -d "${STORAGE_DIR}/rootfs/agent_${AGENT_IDX}" ]]; then
        echo "Installing AZP agent..."
        # Install agent executable
        AZP_AGENTPACKAGE_URL=$(
            curl -LsS -u "user:${AZP_TOKEN}" \
                -H 'Accept:application/json;api-version=3.0-preview' \
                "${AZP_URL}/_apis/distributedtask/packages/agent?platform=linux-x64" |
            jq -r '.value | map([.version.major,.version.minor,.version.patch,.downloadUrl]) | sort | .[length-1] | .[3]'
        )

        if [ -z "$AZP_AGENTPACKAGE_URL" -o "$AZP_AGENTPACKAGE_URL" == "null" ]; then
            echo 1>&2 "error: could not determine a matching Azure Pipelines agent - check that account '$AZP_URL' is correct and the token is valid for that account"
            exit 1
        fi

        AGENT_DIR="${STORAGE_DIR}/rootfs/agent_${AGENT_IDX}"
        mkdir -p "${AGENT_DIR}"
        curl -LsS "$AZP_AGENTPACKAGE_URL" | tar -xz -C "${AGENT_DIR}"
        ln -s "$(pwd)/run_agent.sh" "${AGENT_DIR}/run_agent.sh"
    fi

    export SRC_DIR STORAGE_DIR AGENT_IDX AGENT_ALLOW_RUNASROOT
    envsubst "\$SRC_DIR \$STORAGE_DIR \$AGENT_IDX \$USER"  <"agent_startup.conf" >"${HOME}/.config/systemd/user/bb_azp_agent_${AGENT_IDX}.service"
done

# Reload systemd user daemon
systemctl --user daemon-reload

for AGENT_IDX in $(seq 1 ${NUM_AGENTS}); do
    systemctl --user stop bb_azp_agent_${AGENT_IDX} || true
    # Enable and start AZP agents
    systemctl --user enable bb_azp_agent_${AGENT_IDX}
    systemctl --user start bb_azp_agent_${AGENT_IDX}
done
