#!/bin/bash

set -e

if [ -z "$AZP_URL" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

if [ -z "$AZP_TOKEN" ]; then
  echo 1>&2 "error: missing AZP_TOKEN environment variable"
  exit 1
fi

# Tell the agent to ignore the token env variables
export VSO_AGENT_IGNORE=AZP_TOKEN
export AGENT_ALLOW_RUNASROOT=1

if [[ ! -f .credentials ]]; then
    ./config.sh --unattended \
      --agent "${HOSTNAME}.${AGENT_IDX}" \
      --url "${AZP_URL}" \
      --auth PAT \
      --token "${AZP_TOKEN}" \
      --pool "${AZP_POOL:-Default}" \
      --work _work \
      --replace \
      --acceptTeeEula & wait $!
fi

exec ./externals/node/bin/node ./bin/AgentService.js interactive
