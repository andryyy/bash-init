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
  declare -i retries
  declare -i kill_grace_period
  declare -a signals
  local service
  retries=3
  kill_grace_period=3

  for service in ${!BACKGROUND_PIDS[@]}; do
    pid=${BACKGROUND_PIDS[$service]}
    i=0
    # pid will be 0 if non integer
    [ $pid -ne 0 ] && while [ -d /proc/$pid ] && [ $i -lt $retries ]; do
      ((i++))
      text info "Signaling service $(text debug ${service} color_only) ($pid) that children should not respawn (${i}/${retries})"
      [ -e /proc/$pid/task/$pid/children ] && for child in $(</proc/$pid/task/$pid/children); do
        # Make sure to collect child pids first, then send USR1 signal
        kill -USR1 $pid
        while read signal; do
          i_term=0
          while [ $i_term -lt $kill_grace_period ]; do
            ((i_term++))
            [ -d /proc/$child ] && {
              text info "Sending child processes of service $(text debug ${service} color_only) $child $signal signal (${i_term}/${kill_grace_period})"
              kill -${signal} $child
              # Grace a delay
              read -t 0.3 -u $sleep_fd||:
            }
          done
        done < <(. ${service}.env ; split "$stop_signal" ",")
      done
    done
    [ -d /proc/$pid ] && {
      text warning "PID $pid did not exit, terminating..."
      kill -9 $pid
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
