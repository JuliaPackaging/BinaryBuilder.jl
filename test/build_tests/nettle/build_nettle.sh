#!/bin/bash

set -x

if [[ -z "$1" ]]; then
    echo "Usage: $0 <prefix path>"
    exit 1
fi

prefix="$1"

mkdir build_${target}
if [[ $? != 0 ]]; then
    echo "Could not create directory build_${target}" >&2
    exit 1
fi

cd build_${target}
${prefix}/src/nettle-3.3/configure --host=${target} --prefix=/${target}
if [[ $? != 0 ]]; then
    echo "Configure failed, cat'ing out config.log..." >&2
    cat config.log
    exit 1
fi

make -j4
if [[ $? != 0 ]]; then
    echo "Building failed" >&2
    exit 1
fi

make install
if [[ $? != 0 ]]; then
    echo "Install failed" >&2
    exit 1
fi
