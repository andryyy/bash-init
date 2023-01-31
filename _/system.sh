check_defaults() {
  . _/defaults.config
  for config in ${CONFIG_PARAMS[@]}; do
    [[ "$config" == "command" ]] && continue
    [[ -v $config ]] || {
      text error "Variable $config is missing in defaults"
      has_missing=1
    }
  done
  [[ -v has_missing ]] && exit 1
}

cleanup_bash_init() (
  shopt -s nullglob
  for file in /tmp/bash-init-svc_*; do
    >"$file"
  done
  shopt -u nullglob
)

exit_trap(){
  for service in ${!BACKGROUND_PIDS[@]}; do
    stop_service $service stop &
  done
  text info "Waiting for shutdown jobs to complete"
  wait
  cleanup_bash_init
  text success "Done"
  exit
}

await_stop() {
  # Checks if the state of a PID is T (stopped)
  # declare inside a function automatically makes the variable local
  declare -i pid
  pid=$1
  while proc_exists $pid; do
    [[ "$(proc_status $pid State)" == "T (stopped)" ]] && return 0
    delay 1
  done
  return 1
}

emit_service_stats() {
  declare -i pid
  declare -i memory_usage
  declare -a child_names
  declare -a pid_childs
  local service=$(trim_string "$1")

  pid=${BACKGROUND_PIDS[$service]}
  [ $pid -eq 0 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }

  ! proc_exists -$pid && return 1

  # Read RSS memory usage
  mapfile -n 2 -t rss </proc/$pid/smaps_rollup
  [[ ${rss[1]} =~ ([0-9]+) ]] && {
    memory_usage="${BASH_REMATCH[1]}"
  }

  pid_childs=$(collect_childs $pid)
  for child in ${pid_childs[@]}; do
    ! proc_exists $child && continue
    mapfile -n 2 -t rss </proc/$child/smaps_rollup
    [[ ${rss[1]} =~ ([0-9]+) ]] && {
      memory_usage=$(( $memory_usage + "${BASH_REMATCH[1]}" ))
    }
    if [ $emit_stats_proc_names -eq 1 ]; then
      child_names+=($(printf '"%s[%d]"' "$(</proc/$child/comm)" "$child"))
    else
      child_names+=($(printf '%d' "$child"))
    fi
  done

  health="$(text info "NA" color_only)"
  probe_type="$(env_ctrl "$service" "get" "probe_type")"
  if [ ! -z "$probe_type" ]; then
    health="$(env_ctrl "$service" "get" "active_probe_status")"
    if [ "$health" == "1" ]; then
      health="$(text success "OK" color_only)"
    elif [ "$health" == "0" ]; then
      health="$(text error "BAD" color_only)"
    else
      health="$(text warning "PENDING" color_only)"
    fi
  fi

  text stats \
    "$(printf '{"NAME":"%s","MEMORY":"%skB","CHILDS":[%s],"HEALTH":"%s"}' \
      "$(text info "$service" color_only)" \
      "$(text info "$memory_usage" color_only)" \
      "$(text info "$(join_array "," "${child_names[@]}")" color_only)" \
      "$health"
    )"
}

stop_service() {
  local service=$(trim_string "$1")
  local policy=$(trim_string "$2")
  local command_pid
  declare -i signal_retry=0
  declare -i kill_retry
  declare -i await_exit
  declare -i pid
  declare -a pid_childs
  declare -i pid=${BACKGROUND_PIDS[$service]}

  [ ${#@} -ne 2 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  is_regex_match "$policy" "(restart|stop|reload)" || { text error "${FUNCNAME[0]}: Invalid policy $policy"; return 1; }

  [ $pid -ne 0 ] && while proc_exists $pid && [ $signal_retry -lt $kill_retries ]; do
    ((signal_retry++))
    pid_childs=$(collect_childs $pid)

    if [[ "$policy" == "reload" ]]; then
      signals=$(. /tmp/bash-init-svc_${service} ; printf "$reload_signal")
    else
      signals=$(. /tmp/bash-init-svc_${service} ; split "$stop_signal" ",")
    fi
    for signal in ${signals[@]}; do
      if [[ "$policy" == "reload" ]]; then
        command_pid="$(env_ctrl "$service" "get" "command_pid")"
        kill -${signal} ${command_pid} 2>/dev/null
        text info "Sent command PID $command_pid of container $(text info $service color_only) ($pid) reload signal $signal"
        return 0
      fi
      kill_retry=0
      while [ $kill_retry -lt $kill_retries ] && proc_exists -$pid; do
        ((kill_retry++))
        if kill -${signal} -${pid} 2>/dev/null; then
          text info "Sent service container process group $(text info $service color_only) ($pid) signal $signal (${kill_retry}/${kill_retries})"
          await_exit=0
          while [ $await_exit -lt $max_kill_delay ]; do
            ! proc_exists -${pid} && break
            ((await_exit++))
            # Slow down
            await_exit=$((await_exit<=3?await_exit:await_exit*2))
            text info "Waiting ${await_exit}s for service container process group $(text info $service color_only) ($pid) to stop"
            delay $await_exit
          done
        else
          break
        fi
      done
    done
    for child in ${pid_childs[@]}; do
      proc_exists $child && {
        text warning "Child process $child from service container $(text info $service color_only) ($pid) did not exit, terminating"
        kill -9 $child
      } || {
        text success "Child process $child from service container $(text info $service color_only) is gone"
      }
    done
  done

  [[ "$policy" != "reload" ]] && proc_exists -$pid && {
    text warning "Service container process group $(text info $service color_only) ($pid) did not exit, terminating"
    kill -9 -$pid
  }

  if [[ "$policy" == "stop" ]]; then
    text info "Service container process group $(text info $service color_only) ($pid) will not respawn"
    >/tmp/bash-init-svc_${service}
  fi

}

proc_exists() {
  kill -0 $1 2>/dev/null
}

collect_childs() {
  declare -i pid
  pid=$1
  [ $pid -eq 0 ] && return 1
  [ ! -e "/proc/$pid/task/$pid/children" ] && return 1
  mapfile -t childs < <(split "$(</proc/$pid/task/$pid/children)" " ")
  for child in ${childs[@]}; do
    printf "%s\n" $child
    collect_childs $child;
  done
}

http_probe() {
  # http_probe hostname port path method expected_status_code
  # Example: http_probe www.example.com 80 "/" GET 200
  # Should be called with run_with_timeout to avoid long waits
  [ ${#@} -ne 5 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  local host
  local status_code
  local method
  local path
  declare -i port
  declare -i status_code
  host=$(trim_string "$1")
  port="$2"
  path=$(trim_string "$3")
  method=$(trim_string "$4")
  status_code="$5"
  [ $status_code -eq 0 ] && status_code=200
  [ $port -eq 0 ] && port=80
  exec 3<>/dev/tcp/${host}/${port}
  printf "%s %s HTTP/1.1\r\nhost: %s\r\nConnection: close\r\n\r\n" "$method" "$path" "$host" >&3
  # Read only first line, timeout after 5s without response
  read -u 3 -t 5 response
  is_regex_match "$response" "$(printf "HTTP/1.[0-1] %s" "$status_code")" && return 0
  text debug "Unexpected response by probe $(join_array ":" "${@}") - $(text info "$response" color_only)"
  return 1
}

proc_status() {
  declare -i pid=$1
  local attr=$(trim_string "$2")
  mapfile -t proc_status </proc/${pid}/task/${pid}/status
  for line in "${proc_status[@]}"; do
    print_regex_match "$line" "$(printf '%s:\s(.*)$' $attr)"
  done
}

# Get current or previous value of an env var of a service
#   - env_ctrl get var_name
#   - env_ctrl prev var_name
#
# Set (or auto-update) a new value to an env var of a service
#   - env_ctrl set var_name new_value
#
# Delete a value (and any previous value) of a service
#   - env_ctrl del var_name
#
env_ctrl() (
  local service=$(trim_string "$1")
  local action=$(trim_string "$2")
  local var_name=$(trim_string "$3")
  local new_value=$(trim_string "$4")
  local service_env
  ([[ "$action" == "set" ]] && [ ${#@} -ne 4 ]) || \
  ([[ "$action" != "set" ]] && [ ${#@} -ne 3 ]) && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  [ -s /tmp/bash-init-svc_${service} ] || return 1
  mapfile -t service_env </tmp/bash-init-svc_${service}

  if [[ "$action" == "get" ]]; then
    for line in "${service_env[@]}"; do
      print_regex_match "$line" "^${var_name}=\"(.+)\"$"
    done

  elif [[ "$action" == "prev" ]]; then
    for line in "${service_env[@]}"; do
      print_regex_match "$line" "^_${var_name}=\"(.+)\"$"
    done

  elif [[ "$action" == "set" ]]; then
    local old_value
    declare -i processed=0
    old_value="$(env_ctrl "$service" "get" "$var_name")"

    while [ -s /tmp/env.lock ]; do
      continue
    done
    printf "1" > /tmp/env.lock

    >/tmp/bash-init-svc_${service}
    for line in "${service_env[@]}"; do
      if is_regex_match "$line" "^_${var_name}="; then
        continue
      elif is_regex_match "$line" "^${var_name}="; then
        [ $processed -eq 1 ] && continue
        printf '%s="%s"\n' "${var_name}" "${new_value}" >> /tmp/bash-init-svc_${service}
        processed=1
      else
        printf '%s\n' "${line}" >> /tmp/bash-init-svc_${service}
      fi
    done

    [ $processed -eq 1 ] && \
      printf '_%s="%s"\n' "${var_name}" "${old_value}" >> /tmp/bash-init-svc_${service} || \
      printf '%s="%s"\n' "${var_name}" "${new_value}" >> /tmp/bash-init-svc_${service}
    >/tmp/env.lock

  elif [[ "$action" == "del" ]]; then
    while [ -s /tmp/env.lock ]; do
      continue
    done
    printf "1" > /tmp/env.lock

    >/tmp/bash-init-svc_${service}
    for line in "${service_env[@]}"; do
      if ! is_regex_match "$line" "^${var_name}="; then
        printf '%s\n' "${line}" >> /tmp/bash-init-svc_${service}
      else
        unset $var_name
      fi
    done
    >/tmp/env.lock
  fi
)
