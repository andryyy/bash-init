. $env_file
. _/shared.sh
exec &> /dev/stdout 2>&1
trap "stop=1" USR1
# Waiting for launch command
kill -STOP $$

declare -i i=0
[ ! -z "$probe" ] && {
  readarray -t params < <(split "$probe" ":")
  while ! run_with_timeout http_probe ${params[@]:1} && [ ! -v stop ]; do
    ((i++))
    [ $i -lt $restart_retries ] && {
      text warning "Service $(text debug $service_name color_only) has an unmet HTTP dependency (${i}/${restart_retries})"
      read -rt 3 <> <(:)||:
    } || {
      text error "Service $(text debug $service_name color_only) terminates due to unmet HTTP dependency"
      stop=1
      break
    }
  done
  [ ! -v stop ] && text success "HTTP dependency for service $(text debug $service_name color_only) succeeded"
}

declare -i i=0
while true && [ ! -v stop ]; do
  eval $command
  ec=$?
  [ ! -v stop ] && {
    [[ "$restart" =~ (always|periodic) ]] && {
      text info "Service $(text debug $service_name color_only) did return exit code $ec"
    } || [[ "$restart" == "never" ]] && {
      text error "Service $(text debug $service_name color_only) did exit with exit code $ec, not restarting due to restart policy"
      break
    } || [[ "$restart" == "on-failure" ]] && {
      [[ $ec -eq 0 ]] && {
        text info "Service $(text debug $service_name color_only) did exit with exit code $ec (not a failure), not restarting"
        break
      } || {
        [ $i -lt $restart_retries ] && {
          ((i++))
          text danger "Service $(text debug $service_name color_only) did exit with exit code $ec (failure), restarting (${i}/${restart_retries})"
        } || exit 1
      }
    }
  }
done

# Reap zombies, if any
while kill %1 2>/dev/null; do
  # \o/ pure bash bible
  read -rt 0.1 <> <(:)||:
done
