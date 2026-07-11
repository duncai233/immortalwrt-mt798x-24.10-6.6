#!/usr/bin/env sh
set -eu

cd /root/codex_360t7_build
nohup ./Build360T7Production.sh > build.production.log 2>&1 < /dev/null &
echo "$!" > build.production.pid
echo "production_pid=$(cat build.production.pid)"
