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

# \o/ pure bash bible
trim_string() {
  : "${1#"${1%%[![:space:]]*}"}"
  : "${_%"${_##*[![:space:]]}"}"
  printf '%s' "$_"
}

# \o/ pure bash bible
regex() {
  [[ $1 =~ $2 ]] && printf '%s' "${BASH_REMATCH[1]}"
}

finish() {
  local pid
  local service
  local i
  declare -i retries
  local retries=3
  for service in ${!BACKGROUND_PIDS[@]}; do
    declare -i pid
    pid=${BACKGROUND_PIDS[$service]}
    i=0
    while [ -d /proc/$pid ] && [ $i -lt $retries ]; do
      ((i++))
      text info "Signaling service $(text debug ${service} color_only) ($pid) that children should not respawn (${i}/${retries})"
      kill -USR1 $pid
      for child in $(cat /proc/$pid/task/$pid/children); do
        text info "Sending child procs of service $(text debug ${service} color_only) $child TERM signal (${i}/${retries})"
        kill -TERM $child
      done
      text info "Waiting for children to terminate (${i}/${retries})"
      sleep 0.3
    done
    [ -d /proc/$pid ] && {
      text warning "PID $pid did not exit, terminating..."
      kill -9 $pid
    }
    rm ${service}.env
  done
  exit
}
