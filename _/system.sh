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
  local pid
  local service
  for service in ${!BACKGROUND_PIDS[@]}; do
    pid=${BACKGROUND_PIDS[$service]}
    i=0
    while [ -d /proc/$pid ] && [ $i -lt 2 ]; do
      text info "Signaling service $(text debug ${service} color_only) ($pid) that children should not respawn"
      kill -USR1 $pid
      for child in $(cat /proc/$pid/task/$pid/children); do
        text info "Sending child procs of service $(text debug ${service} color_only) $child TERM signal"
        kill -TERM $child
      done
      text info "Waiting for children to terminate ($i secs passed)"
      sleep 0.3
      ((i++))
    done
    [ -d /proc/$pid ] && {
      text warning "PID $pid did not exit, terminating..."
      kill -9 $pid
    }
    rm ${service}.env
  done
  exit
}
