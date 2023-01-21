#!/usr/bin/env bash

declare -a CONFIG_PARAMS=(restart periodic_interval success_exit restart_retries restart_max_delay probe depends stop_signal dependency_failure_action reload_signal command)
declare -A BACKGROUND_PIDS
. _/defaults.config
. _/system.sh
. _/shared.sh

trap "exit" INT TERM
trap "finish" EXIT

check_defaults

[ $# -eq 0 ] && {
  text error "Missing service name/s in attribute"
  exit 1
}

for i in {1..2}; do
  # On first loop, declare associative arrays
  [ $i -eq 1 ] && {
    for service in ${@}; do
      declare -A $service
    done
  } || {
    # Now source services and process
    . services.array
    for service in ${@}; do
      declare -n "s=$service"
      [ ${#s[@]} -eq 0 ] && { text error  "Service **${service}** is not defined" ; continue ; }
      [ ${#s[command]} -eq 0 ] && { text error "Service **${service}** has no command defined" ; continue ; }
      text info "Starting: $(text debug ${service} color_only)"
      > ${service}.env
      for config in ${CONFIG_PARAMS[@]}; do
        user_config=0
        for attr in ${!s[@]}; do
          [[ "$attr" == "$config" ]] && {
            user_config=1
            echo ${attr}=$(printf '"%s"' "${s[$attr]}") >> ${service}.env
          }
        done
        [ $user_config -eq 0 ] && echo ${config}=$(printf '"%s"' "${!config}") >> ${service}.env
      done
      echo "service_name=${service}" >> ${service}.env
      env_file=${service}.env bash _/task.sh &
      pid=$!
      BACKGROUND_PIDS[$service]=$pid
    done
  }
done

while true; do
  for key in ${!BACKGROUND_PIDS[@]}; do
    text info "Spawned service $(text debug ${key} color_only) with PID ${BACKGROUND_PIDS[$key]}, waiting for child procs"
  done
  sleep inf
done
