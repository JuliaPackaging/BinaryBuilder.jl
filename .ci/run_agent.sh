#!/bin/bash

set -e

if [ -z "$GHA_URL" ]; then
  echo 1>&2 "error: missing GHA_URL environment variable"
  exit 1
fi

if [ -z "$GHA_TOKEN" ]; then
  echo 1>&2 "error: missing GHA_TOKEN environment variable"
  exit 1
fi

export AGENT_ALLOW_RUNASROOT=1
cd /agent
if [[ ! -f .credentials ]]; then
    ./config.sh --unattended \
      --name "${HOSTNAME}.${AGENT_IDX}" \
      --url "${GHA_URL}" \
      --token "${GHA_TOKEN}" \
      --replace
fi

exec ./run.sh
