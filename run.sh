#!/usr/bin/env bash
set -mb
cd "$(dirname "$0")"

declare -ar CONFIG_PARAMS=(system_packages package_manager_lock_wait http_probe_timeout probe_retries restart periodic_interval success_exit probe depends stop_signal reload_signal command probe_interval continous_probe probe_failure_action)
declare -A BACKGROUND_PIDS

. _/defaults.config
. _/bash-init.config
. _/system.sh
. _/tools.sh

cleanup_bash_init

trap "exit" INT TERM
trap "exit_trap" EXIT

check_defaults

[ $# -eq 0 ] && {
  text error "Missing service name/s in attribute"
  exit 1
}

text debug "Spawned bash-init with PID $$"

for i in {1..2}; do
  # On first loop, declare associative arrays
  [ $i -eq 1 ] && {
    for raw_service in ${@}; do
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
    for raw_service in ${@}; do
      service="$(trim_string "$raw_service")"
      declare -n "s=$service"
      [ ${#s[@]} -eq 0 ] && { text error  "Service $service is not defined"; exit 1; }
      [ ${#s[command]} -eq 0 ] && { text error "Service $service has no command defined"; exit 1; }
      text info "Starting: $(text debug $service color_only)"
      > runtime/envs/${service}
      for config in "${CONFIG_PARAMS[@]}"; do
        user_config=0
        for attr in "${!s[@]}"; do
          [[ "$attr" == "$config" ]] && {
            user_config=1
            printf '%s="%s"\n' "$attr" "${s[$attr]}" >> runtime/envs/${service}
          }
        done
        [ $user_config -eq 0 ] && printf '%s="%s"\n' "$config" "${!config}" >> runtime/envs/${service}
      done
      printf 'service_name="%s"\n' "$service" >> runtime/envs/${service}
      env_file=runtime/envs/${service} bash _/task.sh &
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
    if proc_exists $pid; then
      if [ $((run_loop%emit_stats_interval)) -eq 0 ]; then
        emit_pid_stats $pid
        run_loop=0
      fi
      if [ -f runtime/messages/${key}.stop ]; then
        stop_service $key $(<runtime/messages/${key}.stop)
      fi
    else
      if [ -f runtime/envs/${key} ]; then
        env_file=runtime/envs/${key} bash _/task.sh &
        _pid=$!
        BACKGROUND_PIDS[$key]=$_pid
        text warning "Restarting initialization of service container $(text debug $key color_only) with PID $_pid, starting command..."
        await_stop $_pid && {
          kill -CONT $_pid
          text success "Service container $(text debug $key color_only) was started"
        } ||:
      else
        unset BACKGROUND_PIDS[$key]
        cleanup_service_files $key
        text info "Service $key has left the chat"
      fi
    fi
  done
  [ ${#BACKGROUND_PIDS[@]} -eq 0 ] && { text info "No more running services to monitor"; exit 0; }
  sleep 1
done
