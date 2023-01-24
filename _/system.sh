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

finish() {
  # declare inside a function automatically makes the variable local
  declare -i i
  declare -i i_term
  declare -i pid
  declare -a pid_childs
  local service

  for service in ${!BACKGROUND_PIDS[@]}; do
    pid=${BACKGROUND_PIDS[$service]}
    i=0
    # pid will be 0 if non integer
    [ $pid -ne 0 ] && while [ -d /proc/$pid ] && [ $i -lt $kill_retries ]; do
      ((i++))

      # Make sure to collect child pids first, then send USR1 signal:
      #  Some tools like "nc" quit on any signal; we want to make sure we are aware of all childs
      #  before sending a signal.
      pid_childs=$(collect_childs $pid)
      text info "Signaling service container $(text debug ${service} color_only) ($pid) that children should not respawn (${i}/${retries})"
      kill -USR1 $pid

      while read signal; do
        i_term=0
        while [ $i_term -lt $kill_retries ] && [ $((i_term<=3?i_term:i_term*2)) -lt $max_kill_delay ] && [ -d /proc/$pid ]; do
          ((i_term++))
          if kill -${signal} -${pid} 2>/dev/null; then
            text info "Sent service container process group $(text debug ${service} color_only) ($pid) a $signal signal (${i_term}/${kill_retries})"
            [ $i_term -eq 1 ] && read -t $((i_term<=3?i_term:i_term*2)) -u $sleep_fd
          else
            break
          fi
        done
      done < <(. ${service}.env ; split "$stop_signal" ",")

      # todo: reap zombies
      for child in ${pid_childs[@]}; do
        [ -d /proc/$pid ] && {
          text info "Found zombie process $child from service container $(text debug ${service} color_only) ($pid), terminating..."
          kill -9 $child
        } || {
          text success "Child process $child from service container $(text debug ${service} color_only) is gone"
        }
      done

    done

    [ -d /proc/$pid ] && {
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
  [ -d /proc/$pid ] && until regex_match "$(</proc/$pid/status)" 'State:\sT\s'; do
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
