#!/bin/bash

SELF=$$
(sleep 3; kill $SELF) &

# Count 1, 2, 3 then kill yourself
for i in $(seq 1 10); do
    echo $i >&2
    sleep 1
done