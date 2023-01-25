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

proc_exists() {
  kill -0 ${1} 2>/dev/null
}

finish() {
  # declare inside a function automatically makes the variable local
  declare -i i
  declare -i i_term
  declare -i await_exit
  declare -i pid
  declare -a pid_childs
  local service

  for service in ${!BACKGROUND_PIDS[@]}; do
    pid=${BACKGROUND_PIDS[$service]}
    i=0
    # pid will be 0 if non integer
    [ $pid -ne 0 ] && while proc_exists $pid && [ $i -lt $kill_retries ]; do
      ((i++))

      pid_childs=$(collect_childs $pid)
      text info "Signaling service container $(text debug ${service} color_only) ($pid) that children should not respawn (${i}/${kill_retries})"

      while read signal; do
        kill_retry=0
        while [ $kill_retry -lt $kill_retries ] && proc_exists -$pid; do
          ((kill_retry++))
          if kill -${signal} -${pid} 2>/dev/null; then
            text info "Sent service container process group $(text debug ${service} color_only) ($pid) a $signal signal (${kill_retry}/${kill_retries})"
            await_exit=0
            while [ $await_exit -lt $max_kill_delay ]; do
              ! proc_exists -${pid} && break
              ((await_exit++))
              # Slow down
              await_exit=$((await_exit<=3?await_exit:await_exit*2))
              text info "Waiting ${await_exit}s for service container process group $(text debug ${service} color_only) ($pid) to stop"
              read -t $await_exit -u $sleep_fd
            done
          else
            break
          fi
        done
      done < <(. ${service}.env ; split "$stop_signal" ",")

      # todo: reap zombies
      for child in ${pid_childs[@]}; do
        proc_exists $child && {
          text info "Found zombie process $child from service container $(text debug ${service} color_only) ($pid), terminating..."
          kill -9 $child
        } || {
          text success "Child process $child from service container $(text debug ${service} color_only) is gone"
        }
      done

    done

    proc_exists -$pid && {
      text warning "Service container $(text debug ${service} color_only) ($pid) did not exit, terminating..."
      kill -9 -$pid
    }
    rm ${service}.env
  done
  exit
}

await_stop() {
  # Checks if the state of a PID is T (stopped)
  # declare inside a function automatically makes the variable local
  declare -i pid
  pid=$1
  proc_exists $pid && until regex_match "$(</proc/$pid/status)" 'State:\sT\s'; do
    read -t 0.1 -u $sleep_fd||:
  done
}

emit_pid_stats() {
  declare -i pid
  declare -i memory_usage
  declare -a child_names
  declare -a pid_childs

  pid=$1
  [ $pid -eq 0 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }

  ! proc_exists $pid && return

  # Read RSS memory usage
  mapfile -n 2 -t rss </proc/$pid/smaps_rollup
  [[ ${rss[1]} =~ ([0-9]+) ]] && {
    memory_usage="${BASH_REMATCH[1]}"
  }

  pid_childs=$(collect_childs $pid)

  for child in ${pid_childs[@]}; do
    mapfile -n 2 -t rss </proc/$child/smaps_rollup
    [[ ${rss[1]} =~ ([0-9]+) ]] && {
      memory_usage=$(( $memory_usage + "${BASH_REMATCH[1]}" ))
    }
    child_names+=($(printf "%s@%s" "$(</proc/$child/comm)" "$child"))
  done

  text stats \
    $(printf 'NAME:%s;MEMORY:%skB;CHILDS:%s' \
      "$(text debug "$key" color_only)" \
      "$(text debug "$memory_usage" color_only)" \
      "$(text debug "$(join_array ";" "${child_names[@]}")" color_only)"
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
