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
      kill -USR1 $pid
      [ -e /proc/$pid/task/$pid/children ] && for child in $(</proc/$pid/task/$pid/children); do
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
  mapfile -t response <&3
  regex_match "${response[0]}" "$(printf "HTTP/1.1 %s" "${status_code}")" && return 0
  return 1
}

# https://stackoverflow.com/a/24413646
run_with_timeout () {
  declare -i time=3
  regex_match "$1" "^[0-9]+$" && { time=$1; shift; }
  (
    "$@" &
    child=$!
    trap -- "" SIGTERM
    (
      read -rt $time <> <(:)||:
      kill $child 2> /dev/null
    ) &
    wait $child
  )
}
