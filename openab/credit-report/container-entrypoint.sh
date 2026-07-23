#!/bin/bash
set -eu

umask 077
runtime_dir=/run/credit-report
runtime_config="$runtime_dir/openab.toml"
broker_socket="$runtime_dir/discord.sock"

mkdir -p "$runtime_dir"
chmod 0750 "$runtime_dir"
chown root:node "$runtime_dir"

export CREDIT_REPORT_BROKER_SOCKET="$broker_socket"
node /opt/credit-report/runtime-config.mjs \
  /etc/openab/config.toml \
  "$runtime_config"

node /opt/credit-report/discord-broker.mjs &
broker_pid=$!
openab_pid=

terminate() {
  if [ -n "$openab_pid" ]; then
    kill "$openab_pid" 2>/dev/null || true
  fi
  kill "$broker_pid" 2>/dev/null || true
}

stop_and_wait() {
  pid="$1"
  kill "$pid" 2>/dev/null || true
  # OpenAB may acknowledge SIGTERM yet remain blocked in its Discord shutdown.
  # Bound that wait so a dead privileged broker cannot leave the adapter
  # running indefinitely in a misleading half-alive container.
  (
    sleep 5
    kill -KILL "$pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!
  wait "$pid" 2>/dev/null || true
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
}
trap terminate HUP INT TERM EXIT

attempt=0
while [ ! -S "$broker_socket" ]; do
  if ! kill -0 "$broker_pid" 2>/dev/null; then
    wait "$broker_pid"
    exit $?
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    echo "credit-report entrypoint: Discord broker did not become ready" >&2
    exit 1
  fi
  sleep 0.05
done

openab run -c "$runtime_config" &
openab_pid=$!

# Both processes are security-critical. If the root broker disappears, the
# helper cannot retrieve/return attachments, so OpenAB must stop accepting new
# Discord work instead of continuing in a misleading degraded state.
set +e
exited_pid=
wait -n -p exited_pid "$broker_pid" "$openab_pid"
status=$?
set -e
if [ "$exited_pid" = "$broker_pid" ]; then
  echo "credit-report entrypoint: Discord broker exited unexpectedly (status $status); stopping OpenAB" >&2
  stop_and_wait "$openab_pid"
  if [ "$status" -eq 0 ]; then
    status=1
  fi
else
  stop_and_wait "$broker_pid"
fi
exit "$status"
