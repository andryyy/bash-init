check_defaults() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0)" >&2
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
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0)" >&2
  shopt -s nullglob
  for file in /tmp/bash-init-svc_*; do
    >"$file"
  done
  shopt -u nullglob
)

exit_trap(){
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0)" >&2
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
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0)" >&2
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

# A lot of return and continue is used to stop processing when a proc vanishes
emit_service_stats() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0)" >&2
  declare -i pid=0
  declare -i memory_usage=0
  declare -a child_names
  declare -a pid_childs
  local service=$(trim_string "$1")

  pid=${BACKGROUND_PIDS[$service]}
  [ $pid -eq 0 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }

  ! proc_exists $pid && return 1

  2>/dev/null mapfile -n 2 -t rss <"/proc/${pid}/smaps_rollup" || return 1

  is_regex_match "${rss[1]}" "([0-9]+)" \
    && memory_usage="${BASH_REMATCH[1]}" \
    || memory_usage=0

  pid_childs=$(collect_childs $pid)
  for child in ${pid_childs[@]}; do
    2>/dev/null mapfile -n 2 -t rss <"/proc/${child}/smaps_rollup" || continue

    is_regex_match "${rss[1]}" "([0-9]+)" \
      && memory_usage=$(( $memory_usage + "${BASH_REMATCH[1]}" )) \
      || continue

    2>/dev/null read -r comm <"/proc/${child}/comm" || continue
    [[ "$comm" == "bash" ]] && [ $emit_stats_hide_bash -eq 1 ] && continue
    if [ $emit_stats_proc_names -eq 1 ]; then
      child_names+=($(printf '"%s[%d]"' "$comm" "$child"))
    else
      child_names+=($(printf '%d' "$child"))
    fi

  done

  read -d '\n' -r probe_type health health_change \
    <<<"$(env_ctrl sleep get probe_type active_probe_status active_probe_status_change)"

  [ -z "$health" ] && health="$(text info "NA" color_only)"

  if [ ! -z "$probe_type" ]; then
    if [ ! -z "$health_change" ]; then
      time_now=$(printf "%(%s)T")
      health_status_since=$(($time_now - $health_change))
    else
      health_status_since="-"
    fi

    if [ "$health" == "1" ]; then
      health="$(text success "OK" color_only)"
    elif [ "$health" == "0" ]; then
      health="$(text error "BAD" color_only)"
    else
      health="$(text warning "PENDING" color_only)"
    fi
  fi

  text stats \
    "$(printf '{"SERVICE_CONTAINER":"%s","MEMORY":"%skB","CHILDS":[%s],"HEALTH":"%s(%ss)"}' \
      "$(text info "$service" color_only)" \
      "$(text info "$memory_usage" color_only)" \
      "$(text info "$(join_array "," "${child_names[@]}")" color_only)" \
      "$health" \
      "$(text info $health_status_since color_only)"
    )"
}

stop_service() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0)" >&2
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
      while [ $kill_retry -lt $kill_retries ] && proc_exists $pid; do
        ((kill_retry++))

        # In case of premature interrupt:
        if [[ "$(proc_status $pid State)" == "T (stopped)" ]]; then
          text warning "Killing service container $(text info $service color_only) ($pid) while in stopped state"
          kill -9 -$pid
          continue
        fi

        if kill -${signal} -${pid} 2>/dev/null; then
          text info "Sent service container process group $(text info $service color_only) ($pid) signal $signal (${kill_retry}/${kill_retries})"
          await_exit=0
          while [ $await_exit -lt $max_kill_delay ]; do
            ! proc_exists -$pid && break
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

  [[ "$policy" != "reload" ]] && proc_exists $pid && {
    text warning "Service container process group $(text info $service color_only) ($pid) did not exit, terminating"
    kill -9 -$pid
  }

  if [[ "$policy" == "stop" ]]; then
    text info "Service container process group $(text info $service color_only) ($pid) will not respawn"
    >/tmp/bash-init-svc_${service}
  fi

}

proc_exists() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0) \
    with args $(join_array " " "${@}")" >&2
  kill -0 $1 2>/dev/null
}

collect_childs() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0) \
    with args $(join_array " " "${@}")" >&2
  declare -i pid
  pid=$1
  [ $pid -eq 0 ] && return 1
  2>/dev/null mapfile -d ' ' childs <"/proc/$pid/task/$pid/children"
  for child in ${childs[@]}; do
    printf "%s\n" $child
    collect_childs $child;
  done
}

http_probe() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0) \
    with args $(join_array " " "${@}")" >&2
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
  2>/dev/null exec 3<>/dev/tcp/${host}/${port} || return 1
  printf "%s %s HTTP/1.1\r\nhost: %s\r\nConnection: close\r\n\r\n" "$method" "$path" "$host" >&3
  # Read only first line, timeout after 5s without response
  read -u 3 -t 5 response
  is_regex_match "$response" "$(printf "HTTP/1.[0-1] %s" "$status_code")" && return 0
  text debug "Unexpected response by probe $(join_array ":" "${@}") - $(text info "$response" color_only)"
  return 1
}

proc_status() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0)" >&2
  declare -i pid=$1
  local attr=$(trim_string "$2")
  2>/dev/null mapfile -t proc_status </proc/${pid}/task/${pid}/status
  for line in "${proc_status[@]}"; do
    print_regex_match "$line" "$(printf '%s:\s(.*)$' $attr)"
  done
}

# Get current or previous value of one or more env vars of a service
#   - env_ctrl get var_name [var_name2 var_name3 ...]
#   - env_ctrl prev var_name [var_name2 var_name3 ...]
#
# Set (or auto-update) a new value to an env var of a service
#   - env_ctrl set var_name new_value
#
env_ctrl() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0) \
    with args $(join_array " " "${@}")" >&2

  local service=$(trim_string "$1")
  local action=$(trim_string "$2")
  local service_env=
  local -i lock_loop=1

  if [[ "$action" == "set" ]] && [ ${#@} -ne 4 ]; then
    text error "${FUNCNAME[0]}: Invalid arguments"
    return 1
  elif [[ "$action" != "set" ]] && [ ${#@} -lt 3 ]; then
    text error "${FUNCNAME[0]}: Invalid arguments"
    return 1
  fi

  [ -s /tmp/bash-init-svc_${service} ] || return 1

  while [ -s /tmp/env.lock ] && [ $lock_loop -le 20 ]; do
    ((lock_loop++))
    delay 0.1
  done
  # Safety net
  [ $lock_loop -gt 20 ] && { >/tmp/env.lock; return 1; }

  printf "1" >/tmp/env.lock
  trap '>/tmp/env.lock' ERR

  mapfile -t service_env </tmp/bash-init-svc_${service}

  if [[ "$action" == "get" ]] || [[ "$action" == "prev" ]]; then
    shift 2
    for var_name in ${@}; do
      [[ "$action" == "prev" ]] && var_name="_${var_name}"
      # Very important: Unset if previously existing
      declare -n v=$var_name
      [ -v v ] && unset ${!v}
      printf '%s\n' "$(. /tmp/bash-init-svc_${service} ; printf "$v")"
    done

  elif [[ "$action" == "set" ]]; then
    declare -i processed=0
    local old_value=
    local var_name=$(trim_string "$3")
    local new_value=$(trim_string "$4")
    declare -n ov=$var_name

    >/tmp/.bash-init-svc_${service}

    old_value=$(printf '%s\n' "$(. /tmp/bash-init-svc_${service} ; printf "$ov")")

    for line in "${service_env[@]}"; do
      IFS='=' read -r k v <<<${line}
      [ "${k##\#*}" ] || continue;
      [[ "$k" == "_${var_name}" ]] && continue
      if [[ "$k" == "${var_name}" ]]; then
        [ $processed -eq 1 ] && continue
        printf '%s="%s"\n' "${var_name}" "${new_value}" \
          >> /tmp/.bash-init-svc_${service}
        processed=1
      else
        printf '%s="%s"\n' "${k}" "$(eval k="$v"; printf '%s' "$k";)" \
          >> /tmp/.bash-init-svc_${service}
      fi
    done

    if [ $processed -eq 1 ] && [ ! -z "$old_value" ]; then
      printf '_%s="%s"\n' "${var_name}" "${old_value}" \
        >> /tmp/.bash-init-svc_${service}
    else
      printf '%s="%s"\n' "${var_name}" "${new_value}" \
        >> /tmp/.bash-init-svc_${service}
    fi
    echo "$(</tmp/.bash-init-svc_${service})" >/tmp/bash-init-svc_${service}

  elif [[ "$action" == "del" ]]; then
    local var_name=$(trim_string "$3")

    >/tmp/.bash-init-svc_${service}
    for line in "${service_env[@]}"; do
      IFS='=' read -r k v <<<${line}
      [ "${k##\#*}" ] || continue;
      [[ "$k" == "${var_name}" ]] && continue
      printf '%s="%s"\n' "${k}" "$(eval k="$v"; printf '%s' "$k";)" \
        >> /tmp/.bash-init-svc_${service}
    done
    echo "$(</tmp/.bash-init-svc_${service})" >/tmp/bash-init-svc_${service}
  fi

  >/tmp/env.lock
}
