#!/usr/bin/env bash
set -mb
cd "$(dirname "$0")"

rm -f runtime/*env

declare -ar CONFIG_PARAMS=(system_packages http_probe_timeout probe_tries restart periodic_interval success_exit probe depends stop_signal reload_signal command probe_interval continous_probe probe_failure_action)
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
      > runtime/${service}.env
      for config in "${CONFIG_PARAMS[@]}"; do
        user_config=0
        for attr in "${!s[@]}"; do
          [[ "$attr" == "$config" ]] && {
            user_config=1
            printf '%s="%s"\n' "$attr" "${s[$attr]}" >> runtime/${service}.env
          }
        done
        [ $user_config -eq 0 ] && printf '%s="%s"\n' "$config" "${!config}" >> runtime/${service}.env
      done
      printf 'service_name="%s"\n' "$service" >> runtime/${service}.env
      env_file=runtime/${service}.env bash _/task.sh &
      pid=$!
      BACKGROUND_PIDS[$service]=$pid
      text info "Spawned service container $(text debug $service color_only) with PID $pid, preparing environment..."
    done
  }
done

declare -i pid
for key in "${!BACKGROUND_PIDS[@]}"; do
  pid=${BACKGROUND_PIDS[$key]}
  if await_stop $pid; then
    kill -CONT $pid
    text success "Service container $(text debug $key color_only) was initialized"
  else
    text error "Service container $(text debug $key color_only) could not be initialized"
    #todo: optional unset BACKGROUND_PIDS[$key]
  fi
done

declare -i run_loop=0
while true; do
  ((run_loop++))
  for key in ${!BACKGROUND_PIDS[@]}; do
    pid=${BACKGROUND_PIDS[$key]}
    proc_exists $pid && {
      [ $((run_loop%emit_stats_interval)) -eq 0 ] && emit_pid_stats $pid ||:
    } || {
      [ -f runtime/${key}.env ] && {
        env_file=runtime/${key}.env bash _/task.sh &
        _pid=$!
        BACKGROUND_PIDS[$key]=$_pid
        text warning "Restarting initialization of service container $(text debug $key color_only) with PID $_pid, starting command..."
        await_stop $_pid && {
          kill -CONT $_pid
          text success "Service container $(text debug $key color_only) was started"
        } ||:
      } || {
        unset BACKGROUND_PIDS[$key]
        text info "Service $key has left the chat"
      }
    }
  done
  [ ${#BACKGROUND_PIDS[@]} -eq 0 ] && { text info "No more running services to monitor"; exit 0; }
  read -t 1 -u $sleep_fd||:
done
