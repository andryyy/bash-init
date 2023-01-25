#!/usr/bin/env bash
set -mb
cd "$(dirname "$0")"
declare -ar CONFIG_PARAMS=(system_packages restart periodic_interval success_exit probe depends stop_signal dependency_failure_action reload_signal command)
declare -A BACKGROUND_PIDS

. _/defaults.config
. _/bash-init.config
. _/system.sh
. _/shared.sh

trap "exit" INT TERM
trap "finish" EXIT

check_defaults

[ $# -eq 0 ] && {
  text error "Missing service name/s in attribute"
  exit 1
}

exec {sleep_fd}<> <(:)

text debug "Spawned bash-init with PID $$"

for i in {1..2}; do
  # On first loop, declare associative arrays
  [ $i -eq 1 ] && {
    for raw_service in "${@}"; do
      service="$(trim_string "$raw_service")"
      ! regex_match "$service" '^(#?([a-zA-Z0-9_]+))$' && {
        text error "Invalid service name: ${service}"
        exit 1
      }
      declare -A $service
    done
  } || {
    # Now source services and process
    . services.array
    for raw_service in "${@}"; do
      service="$(trim_string "$raw_service")"
      declare -n "s=$service"
      [ ${#s[@]} -eq 0 ] && { text error  "Service $service is not defined"; exit 1; }
      [ ${#s[command]} -eq 0 ] && { text error "Service $service has no command defined"; exit 1; }
      text info "Starting: $(text debug $service color_only)"
      > ${service}.env
      for config in "${CONFIG_PARAMS[@]}"; do
        user_config=0
        for attr in "${!s[@]}"; do
          [[ "$attr" == "$config" ]] && {
            user_config=1
            printf '%s="%s"\n' "$attr" "${s[$attr]}" >> ${service}.env
          }
        done
        [ $user_config -eq 0 ] && printf '%s="%s"\n' "$config" "${!config}" >> ${service}.env
      done
      printf 'service_name="%s"\n' "$service" >> ${service}.env
      env_file=${service}.env bash _/task.sh &
      pid=$!
      BACKGROUND_PIDS[$service]=$pid
    done
  }
done

declare -i pid
for key in "${!BACKGROUND_PIDS[@]}"; do
  pid=${BACKGROUND_PIDS[$key]}
  text info "Spawned service container $(text debug $key color_only) with PID $pid, preparing environment..."
  await_stop $pid
  proc_exists -$pid && {
    kill -CONT $pid
    text info "Service $(text debug $key color_only) is ready and was started"
  }
done

declare -i run_loop=0
while true; do
  ((run_loop++))
  for key in ${!BACKGROUND_PIDS[@]}; do
    pid=${BACKGROUND_PIDS[$key]}
    proc_exists -$pid && {
      [ $((run_loop%emit_stats_interval)) -eq 0 ] && emit_pid_stats $pid ||:
    } || {
      [ -f ${key}.env ] && {
        env_file=${key}.env bash _/task.sh &
        _pid=$!
        await_stop $_pid
        text info "Respawned service container $(text debug $key color_only) with PID $_pid, starting command..."
        kill -CONT $_pid
        text info "Service $(text debug $key color_only) started"
        BACKGROUND_PIDS[$key]=$!
      } || {
        unset BACKGROUND_PIDS[$key]
        text info "Service $key has left the chat"
      }
    }
  done
  [ ${#BACKGROUND_PIDS[@]} -eq 0 ] && { text info "No more running services to monitor"; exit 0; }
  read -t 1 -u $sleep_fd||:
done
