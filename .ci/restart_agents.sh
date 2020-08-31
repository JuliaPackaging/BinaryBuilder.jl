#!/bin/bash

NUM_AGENTS=1
for AGENT_IDX in $(seq 1 ${NUM_AGENTS}); do
    systemctl --user restart bb_gha_agent_${AGENT_IDX}
done
