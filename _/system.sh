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

# Return 0 as the last rm command may return 1 on non-existing files
cleanup_bash_init() {
  rm -f runtime/envs/*
  rm -f runtime/probes/http/*
  rm -f runtime/probes/tcp/*
  rm -f runtime/envs/*
  rm -f runtime/messages/*
  return 0
}

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
    sleep 0.1
  done
  return 1
}

emit_pid_stats() {
  declare -i pid
  declare -i memory_usage
  declare -a child_names
  declare -a pid_childs

  pid=$1
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
    child_names+=($(printf '"%s[%d]"' "$(</proc/$child/comm)" "$child"))
  done

  health="$(text debug "NA" color_only)"
  if [ -s runtime/messages/${key}.probe_type ]; then
    probe_type=$(<runtime/messages/${key}.probe_type)
    if is_regex_match "$probe_type" "(http|tcp)" && [ -s runtime/probes/${probe_type}/${key} ]; then
      health=$(<runtime/probes/${probe_type}/${key})
      if [ $health -eq 1 ]; then
        health="$(text success "OK" color_only)"
      elif [ $health -eq 0 ]; then
        health="$(text error "BAD" color_only)"
      else
        health="$(text warning "PENDING" color_only)"
      fi
    fi
  fi

  text stats \
    $(printf '{"NAME":"%s","MEMORY":"%skB","CHILDS":[%s],"HEALTH":"%s"}\n' \
      "$(text debug "$key" color_only)" \
      "$(text debug "$memory_usage" color_only)" \
      "$(text debug "$(join_array "," "${child_names[@]}")" color_only)" \
      "$health"
    )
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
  is_regex_match "$policy" "(restart|stop|reload)" || { text error "${FUNCNAME[0]}: Invalid policy"; return 1; }

  [ $pid -ne 0 ] && while proc_exists $pid && [ $signal_retry -lt $kill_retries ]; do
    ((signal_retry++))
    pid_childs=$(collect_childs $pid)

    if [[ "$policy" == "reload" ]]; then
      signals=$(. runtime/envs/${service} ; printf "$reload_signal")
    else
      signals=$(. runtime/envs/${service} ; split "$stop_signal" ",")
    fi
    for signal in ${signals[@]}; do
      if [[ "$policy" == "reload" ]]; then
        command_pid=$(proc_env $pid "command_pid")
        kill -${signal} ${command_pid} 2>/dev/null
        text info "Sent command PID $command_pid of container $(text debug $service color_only) ($pid) reload signal $signal"
        >runtime/messages/${service}.signal
        return 0
      fi
      kill_retry=0
      while [ $kill_retry -lt $kill_retries ] && proc_exists -$pid; do
        ((kill_retry++))
        if kill -${signal} -${pid} 2>/dev/null; then
          text info "Sent service container process group $(text debug $service color_only) ($pid) signal $signal (${kill_retry}/${kill_retries})"
          await_exit=0
          while [ $await_exit -lt $max_kill_delay ]; do
            ! proc_exists -${pid} && break
            ((await_exit++))
            # Slow down
            await_exit=$((await_exit<=3?await_exit:await_exit*2))
            text info "Waiting ${await_exit}s for service container process group $(text debug $service color_only) ($pid) to stop"
            sleep $await_exit
          done
        else
          break
        fi
      done
    done
    for child in ${pid_childs[@]}; do
      proc_exists $child && {
        text warning "Child process $child from service container $(text debug $service color_only) ($pid) did not exit, terminating"
        kill -9 $child
      } || {
        text success "Child process $child from service container $(text debug $service color_only) is gone"
      }
    done
  done

  [[ "$policy" != "reload" ]] && proc_exists -$pid && {
    text warning "Service container process group $(text debug $service color_only) ($pid) did not exit, terminating"
    kill -9 -$pid
  }

  if [[ "$policy" == "stop" ]]; then
    text info "Service container process group $(text debug $service color_only) ($pid) will not respawn"
    cleanup_service_files $service 1 1 1
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

cleanup_service_files() {
  declare -i env=$2 probes=$3 messages=$4
  local service_name=$(trim_string "$1")
  [ $env -eq 1 ] && rm -f runtime/envs/${service_name}
  [ $probes -eq 1 ] && rm -f runtime/probes/http/${service_name} runtime/probes/tcp/${service_name}
  [ $messages -eq 1 ] && rm -f runtime/messages/${service_name}.*
  return 0
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
  text debug "Unexpected response by probe $(join_array ":" "${@}") - $(text debug "$response" color_only)"
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

proc_env() {
  declare -i pid=$1
  local attr=$(trim_string "$2")
  mapfile -d '' -t proc_env </proc/${pid}/environ
  for line in "${proc_env[@]}"; do
    print_regex_match "$line" "$(printf '%s=(.*)$' $attr)"
  done
}
