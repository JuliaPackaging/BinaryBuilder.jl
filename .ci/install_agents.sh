#!/bin/bash

set -e

NUM_AGENTS=1
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

    # Install Julia
    echo "Installing Julia..."
    mkdir -p "${STORAGE_DIR}/rootfs/depot"
    JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.5/julia-1.5.1-linux-x86_64.tar.gz"
    curl -# -L "$JULIA_URL" | tar --strip-components=1 -zx -C "${STORAGE_DIR}/rootfs/usr"
fi

if [[ ! -d "${STORAGE_DIR}/rootfs/agent" ]]; then
    # Install agent executable
    AGENT_VERSION=2.273.1
    AGENT_URL=https://github.com/actions/runner/releases/download/v${AGENT_VERSION}/actions-runner-linux-x64-${AGENT_VERSION}.tar.gz

    echo "Installing GHA agent..."
    mkdir -p "${STORAGE_DIR}/rootfs/agent"
    curl -LsS "$AGENT_URL" | tar -xz -C "${STORAGE_DIR}/rootfs/agent"
    sudo chroot ${STORAGE_DIR}/rootfs /agent/bin/installdependencies.sh
fi

for AGENT_IDX in $(seq 1 $NUM_AGENTS); do
    export SRC_DIR STORAGE_DIR AGENT_IDX AGENT_ALLOW_RUNASROOT
    envsubst "\$SRC_DIR \$STORAGE_DIR \$AGENT_IDX \$USER"  <"agent_startup.conf" >"${HOME}/.config/systemd/user/bb_gha_agent_${AGENT_IDX}.service"
done

if [[ ! -f "${STORAGE_DIR}/rootfs/agent/.credentials" ]]; then
    /bin/bash -c "cd ${STORAGE_DIR}/rootfs//agent; ./config.sh --name ${HOSTNAME}.${AGENT_IDX} --url ${GHA_URL} --replace"
fi

# Reload systemd user daemon
systemctl --user daemon-reload

for AGENT_IDX in $(seq 1 ${NUM_AGENTS}); do
    systemctl --user stop bb_gha_agent_${AGENT_IDX} || true
    # Enable and start AZP agents
    systemctl --user enable bb_gha_agent_${AGENT_IDX}
    systemctl --user start bb_gha_agent_${AGENT_IDX}
done
