#!/bin/sh
command -v perl >/dev/null 2>&1 || exit 0
exec perl "$(dirname "$0")/stop-check.pl"
