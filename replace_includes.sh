#!/bin/sh
# -r = recursive
# -l = files-with-matches
# -i = in-place
grep -r -l "#include <$1.h>" . | xargs sed -i "s/#include <$1.h>/#include <$2.h>/"
