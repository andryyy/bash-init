. $env_file
. _/shared.sh
# Do not allow for new process groups when running $command
# This will prevent dedicated process groups and therefore zombie procs
# Also disallow file globbing
set -bf +m
exec &> /dev/stdout 2>&1
trap "stop=1" USR1

# Waiting for launch command
# This does also work when setting +m as we spawned this task in job control mode
kill -STOP $$

mapfile -t packages < <(split "$system_packages" ",")
for p in ${packages[@]}; do
  command -v apk >/dev/null && { apk --wait 30 add $(trim_string "$p"); break; } || \
  command -v apt >/dev/null && { apt install $(trim_string "$p"); break; } || \
  text error "Cannot install additional system packages for service $(text debug $service_name color_only)"
done

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
  ec=$?

  [ ! -v stop ] && {

    # Check for success exit codes
    for e in ${expected_exits[@]}; do
      regex_match "$e" "^[0-9]+$" && [[ $ec -eq $e ]] && exit_ok=1
    done

    # The command was executed, check how to handle restarts
    # never
    [[ "$restart" == "never" ]] && {
      [[ $exit_ok -eq 1 ]] && \
        text info "Service $(text debug $service_name color_only) did exit with expected exit code $ec" || \
        text info "Service $(text debug $service_name color_only) did exit with unexpected exit code $ec, not restarting due to restart policy never"
      break
    }

    # always|periodic
    [[ "$restart" =~ always|periodic ]] && {
      text info "Service $(text debug $service_name color_only) did return exit code $ec, restarting due to policy: $restart"
      continue
    }

    # on-failure
    [[ "$restart" == "on-failure" ]] && {
      [[ $exit_ok -eq 1 ]] && {
        text success "Service $(text debug $service_name color_only) did return $ec (expected: ${success_exit}), not restarting"
        break
      }

      # Exit code does not indicate success
      [ $i -lt $restart_retries ] && [ $((i<=3?i:i*2)) -lt $max_restart_delay ] && {
          ((i++))
          read -rt $((i<=3?i:i*2)) <> <(:)||:
          text danger "Service $(text debug $service_name color_only) did exit with exit code $ec (failure), restarting (${i}/${restart_retries})"
      } || {
        text danger "Service $(text debug $service_name color_only) did exit with exit code $ec (failure), giving up"
        break
      }
    }
  }
done

text info "Self-destroying service container (process group $$) of service $(text debug $service_name color_only) now"
kill -TERM -$$
