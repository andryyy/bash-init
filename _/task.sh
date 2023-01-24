. $env_file
. _/shared.sh
# Do not allow for new process groups when running $command
# This will prevent dedicated process groups and therefore zombie procs
# Also disallow file globbing
set -bf
set +m
exec &> /dev/stdout 2>&1
trap "stop=1" USR1

# Waiting for launch command
# This does also work when setting +m as we spawned this task in job control mode
kill -STOP $$

# Install additional packages
mapfile -t packages < <(split "$system_packages" ",")
[ ${#packages[@]} -ne 0 ] && {
  text info "Installing additional system packages for service $(text debug $service_name color_only): $(trim_all "${packages[@]}")"
  if command -v apk >/dev/null; then
    apk --wait 30 add $(trim_all "${packages[@]}")
  elif command -v apt >/dev/null; then
    apt install $(trim_all "${packages[@]}")
  else
    text error "Cannot install additional system packages for service $(text debug $service_name color_only)"
  fi ;
}

# Run probes
declare -i i=0
[ ! -z "$probe" ] && {
  mapfile -t params < <(split "$probe" ":")
  while ! run_with_timeout http_probe ${params[@]:1} && [ ! -v stop ]; do
    ((i++))
    [ $i -lt $restart_retries ] && {
      text warning "Service $(text debug $service_name color_only) has an unmet HTTP dependency (${i}/${restart_retries})"
      read -rt $((2*$i)) <> <(:)||:
    } || {
      text error "Service $(text debug $service_name color_only) terminates due to unmet HTTP dependency"
      stop=1
      break
    }
  done
  [ ! -v stop ] && text success "HTTP dependency for service $(text debug $service_name color_only) succeeded"
}

declare -i i=0
declare -i exit_ok=0
mapfile -t expected_exits < <(split "$success_exit" ",")

while true && [ ! -v stop ]; do
  $command &
  wait -f $!
  command_exit_code=$?

  [ ! -v stop ] && {
    # Check for success exit codes
    for e in ${expected_exits[@]}; do
      regex_match "$e" "^[0-9]+$" && [[ $command_exit_code -eq $e ]] && exit_ok=1
    done

    # The command was executed, check how to handle restarts
    # never
    [[ "$restart" == "never" ]] && {
      [[ $exit_ok -eq 1 ]] && \
        text info "Service $(text debug $service_name color_only) did exit with expected exit code $command_exit_code" || \
        text info "Service $(text debug $service_name color_only) did exit with unexpected exit code $command_exit_code, not restarting due to restart policy never"
      break
    }

    # always|periodic
    [[ "$restart" =~ always|periodic ]] && {
      text info "Service $(text debug $service_name color_only) did return exit code $command_exit_code, restarting due to policy: $restart"
      continue
    }

    # on-failure
    [[ "$restart" == "on-failure" ]] && {
      [[ $exit_ok -eq 1 ]] && {
        text success "Service $(text debug $service_name color_only) did return $command_exit_code (expected: ${success_exit}), not restarting"
        break
      }

      # Exit code does not indicate success
      [ $i -lt $restart_retries ] && [ $((i<=3?i:i*2)) -lt $max_restart_delay ] && {
          ((i++))
          read -rt $((i<=3?i:i*2)) <> <(:)||:
          text danger "Service $(text debug $service_name color_only) did exit with exit code $command_exit_code (failure), restarting (${i}/${restart_retries})"
      } || {
        text danger "Service $(text debug $service_name color_only) did exit with exit code $command_exit_code (failure), giving up"
        break
      }
    }
  }
done

text info "Self-destroying service container (process group $$) of service $(text debug $service_name color_only) now"
kill -TERM -$$
