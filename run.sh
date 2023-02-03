#!/usr/bin/env bash
set -mb
cd "$(dirname "$0")"

declare -ar CONFIG_PARAMS=(depends_grace_period system_packages package_manager_lock_wait probe_as_dependency probe_timeout probe_retries restart periodic_interval success_exit probe depends stop_signal reload_signal command probe_interval continous_probe probe_failure_action)
declare -A BACKGROUND_PIDS

for parameter in ${@}; do
  shift
  if [[ "$parameter" =~ (-d|--debug) ]]; then
    debug=1
  else
    set -- "$@" "$parameter"
  fi
done

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

text info "Spawned bash-init with PID $$"

for i in {1..2}; do
  # On first loop, declare associative arrays
  [ $i -eq 1 ] && {
    for raw_service in ${@}; do
      service="$(trim_string "$raw_service")"
      ! is_regex_match "$service" '^[a-zA-Z0-9_]+$' && {
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
      text info "$(stage_text stage_1) Starting: $(text info $service color_only)"
      > /tmp/bash-init-svc_${service}
      for config in "${CONFIG_PARAMS[@]}"; do
        user_config=0
        for attr in "${!s[@]}"; do
          [[ "$attr" == "$config" ]] && {
            user_config=1
            printf '%s="%s"\n' "$attr" "${s[$attr]}" >> /tmp/bash-init-svc_${service}
          }
        done
        [ $user_config -eq 0 ] && printf '%s="%s"\n' "$config" "${!config}" >> /tmp/bash-init-svc_${service}
      done
      printf 'service_name="%s"\n' "$service" >> /tmp/bash-init-svc_${service}
      env_file=/tmp/bash-init-svc_${service} bash _/task.sh &
      pid=$!
      BACKGROUND_PIDS[$service]=$pid
      text success "$(stage_text stage_1) Spawned service container $(text info $service color_only) with PID $pid"
    done
  }
done

declare -i pid
declare -i health_check_loop=0
declare -i stage_2_loop=0
declare -A started_containers
declare -a service_dependencies
while [ ${#started_containers[@]} -ne ${#BACKGROUND_PIDS[@]} ]; do
  for key in "${!BACKGROUND_PIDS[@]}"; do
    ((stage_2_loop++))
    mapfile -t service_dependencies < <(. /tmp/bash-init-svc_${key} ; split "$depends" ",")
    for service_dependency in ${service_dependencies[@]}; do
      declare -n "sd=$service_dependency"
      if [ ${#sd[@]} -eq 0 ]; then
        text error \
        "Dependency $(text info $service_dependency color_only) of service \
        $(text info $key color_only) is not a defined service"
        exit 1
      elif [ "$service_dependency" == "$key" ]; then
        text error "Service $(text info $key color_only) depends on itself"
        exit 1
      else
        if [ ${#started_containers[$service_dependency]} -eq 0 ]; then
          [ $((stage_2_loop%5)) -eq 0 ] && text info "$(stage_text stage_2) Service $(text info $key color_only) is awaiting service dependency $(text info $service_dependency color_only)"
          continue 2
        else
          if [ ! -z "$(env_ctrl "$service_dependency" "get" "probe")" ] && \
             [ "$(env_ctrl "$service_dependency" "get" "active_probe_status")" != "1" ]; then

            declare -i depends_grace_period
            depends_grace_period="$(env_ctrl "$service_dependency" "get" "depends_grace_period")"
            ((health_check_loop++))

            if [ $health_check_loop -gt $depends_grace_period ]; then
              text error "$(stage_text stage_2) Service $(text info $key color_only) will be configured to self-destroy \
                due to unhealthy dependency $(text info $service_dependency color_only)"

              # Remove dependency to stop looping over it
              env_ctrl "$key" "set" "depends" ""
              # Tell service container to self-destroy
              env_ctrl "$key" "set" "pending_signal" "stop"
              health_check_loop=0
            fi

            if [ $health_check_loop -gt 1 ]; then
              [ $((health_check_loop%5)) -eq 0 ] && text info "$(stage_text stage_2) Service $(text info $key color_only) is awaiting \
                healthy state of service dependency $(text info $service_dependency color_only), delaying"
              delay 1
            fi

            continue 2
          fi
        fi
      fi
    done
    [ ${#started_containers[$key]} -eq 0 ] && {
      pid=${BACKGROUND_PIDS[$key]}
      if await_stop $pid; then
        started_containers[$key]=1
        kill -CONT $pid
        text success "$(stage_text stage_2) Service container $(text info $key color_only) was initialized"
        delay 3
      else
        text error "$(stage_text stage_2) Service container $(text info $key color_only) could not be initialized"
        exit 1
      fi
    }
  done
done

declare -i run_loop=0
while true; do
  ((run_loop++))
  for key in ${!BACKGROUND_PIDS[@]}; do
    pid=${BACKGROUND_PIDS[$key]}
    if proc_exists $pid; then
      [ $((run_loop%emit_stats_interval)) -eq 0 ] && {
        emit_service_stats $key
        run_loop=0
      }
      pending_signal="$(env_ctrl "$key" "get" "pending_signal")"
      if [ ! -z "$pending_signal" ]; then
        env_ctrl "$key" "del" "pending_signal"
        stop_service "$key" "$pending_signal"
      fi
    else
      if [ -s /tmp/bash-init-svc_${key} ]; then
        while [ -s /tmp/env.lock ]; do
          delay 0.1
        done
        env_file=/tmp/bash-init-svc_${key} bash _/task.sh &
        _pid=$!
        BACKGROUND_PIDS[$key]=$_pid
        text warning "Restarting initialization of service container $(text info $key color_only) with PID $_pid"
        await_stop $_pid && {
          kill -CONT $_pid
          text success "Service container $(text info $key color_only) was started"
        }
      else
        unset BACKGROUND_PIDS[$key]
        kill -$pid 2>/dev/null
        kill $pid 2>/dev/null
        >/tmp/bash-init-svc_${key}
        text info "Service $key has left the chat"
      fi
    fi
  done
  [ ${#BACKGROUND_PIDS[@]} -eq 0 ] && { text info "No more running services to monitor"; exit 0; }
  delay 1
done
