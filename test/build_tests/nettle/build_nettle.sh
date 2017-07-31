#!/bin/bash

set -x
set -e

if [[ -z "$1" ]]; then
    echo "Usage: $0 <prefix path>"
    exit 1
fi

prefix="$1"

mkdir build_${target}
cd build_${target}
${prefix}/src/nettle-3.3/configure --host=${target} --prefix="${prefix}"
make -j4
make install