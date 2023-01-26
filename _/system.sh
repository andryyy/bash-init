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

proc_exists() {
  kill -0 $1 2>/dev/null
}

exit_trap(){
  for service in ${!BACKGROUND_PIDS[@]}; do
    stop_service $service &
  done
  text info "Waiting for shutdown jobs to complete"
  wait
  cleanup_bash_init
  text success "Done"
  exit
}

stop_service() {
  local service=$(trim_string "$1")
  declare -i signal_retry=0
  declare -i kill_retry
  declare -i await_exit
  declare -i pid
  declare -a pid_childs
  declare -a stop_services
  declare -i pid=${BACKGROUND_PIDS[$service]}

  [ $pid -ne 0 ] && while proc_exists $pid && [ $signal_retry -lt $kill_retries ]; do
    echo 1 > runtime/messages/${service}.terminate
    ((signal_retry++))
    pid_childs=$(collect_childs $pid)

    while read signal; do
      kill_retry=0
      while [ $kill_retry -lt $kill_retries ] && proc_exists -$pid; do
        ((kill_retry++))
        if kill -${signal} -${pid} 2>/dev/null; then
          text info "Sent service container process group $(text debug ${service} color_only) ($pid) signal $signal (${kill_retry}/${kill_retries})"
          await_exit=0
          while [ $await_exit -lt $max_kill_delay ]; do
            ! proc_exists -${pid} && break
            ((await_exit++))
            # Slow down
            await_exit=$((await_exit<=3?await_exit:await_exit*2))
            text info "Waiting ${await_exit}s for service container process group $(text debug ${service} color_only) ($pid) to stop"
            sleep $await_exit
          done
        else
          break
        fi
      done
    done < <(. runtime/envs/${service} ; split "$stop_signal" ",")

    for child in ${pid_childs[@]}; do
      proc_exists $child && {
        text warning "Child process $child from service container $(text debug ${service} color_only) ($pid) did not exit, terminating"
        kill -9 $child
      } || {
        text success "Child process $child from service container $(text debug ${service} color_only) is gone"
      }
    done

  done

  proc_exists -$pid && {
    text warning "Service container process group $(text debug ${service} color_only) ($pid) did not exit, terminating"
    kill -9 -$pid
  }

  unset BACKGROUND_PIDS[$service]
}

await_stop() {
  # Checks if the state of a PID is T (stopped)
  # declare inside a function automatically makes the variable local
  declare -i pid
  pid=$1
  while proc_exists $pid; do
    regex_match "$(</proc/$pid/status)" 'State:\sT\s' && return 0
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
    child_names+=($(printf "%s[%d]" "$(</proc/$child/comm)" "$child"))
  done

  for health_probe in runtime/probes/{http,tcp}/${key}; do
    [ -f $health_probe ] && {
      health=$(<$health_probe);
      [ $health -eq 1 ] && \
        health="$(text success "OK" color_only)" || \
        health="$(text error "BAD" color_only)"
      break
    }
    health="$(text debug "NA" color_only)"
  done

  text stats \
    $(printf 'NAME:%s;MEMORY:%skB;CHILDS:%s;HEALTH:%s\n' \
      "$(text debug "$key" color_only)" \
      "$(text debug "$memory_usage" color_only)" \
      "$(text debug "$(join_array ";" "${child_names[@]}")" color_only)" \
      "$health"
    )
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
