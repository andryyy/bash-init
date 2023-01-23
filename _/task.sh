. $env_file
. _/shared.sh
exec &> /dev/stdout 2>&1
trap "stop=1" USR1
trap 'echo test' RETURN
# Waiting for launch command
kill -STOP $$

mapfile -t packages < <(split "$system_packages" ",")
for p in ${packages[@]}; do
  command -v apk && apk --wait 30 add $(trim_string "$p")
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
while true && [ ! -v stop ]; do
  eval $command &
  wait -f $!
  ec=$?
  [ ! -v stop ] && {
    [[ "$restart" =~ always|periodic ]] && {
      text info "Service $(text debug $service_name color_only) did return exit code $ec, restarting due to policy: $restart"
      continue
    }

    [[ "$restart" == "never" ]] && {
      text error "Service $(text debug $service_name color_only) did exit with exit code $ec, not restarting due to restart policy"
      break
    }

    [[ "$restart" == "on-failure" ]] && {
      exit_ok=0
      mapfile -t expected_exits < <(split "$success_exit" ",")
      for e in ${expected_exits[@]}; do
        regex_match "$e" "^[0-9]+$" && [[ $ec -eq $e ]] && exit_ok=1
      done

      [[ $exit_ok -eq 1 ]] && {
        text success "Service $(text debug $service_name color_only) did return $ec (expected: ${success_exit}), not restarting"
        break
      } || {
        [ $i -lt $restart_retries ] && [ $((i<=3?i:i*2)) -lt $max_restart_delay ] && {
          ((i++))
          read -rt $((i<=3?i:i*2)) <> <(:)||:
          text danger "Service $(text debug $service_name color_only) did exit with exit code $ec (failure), restarting (${i}/${restart_retries})"
        } || {
          text danger "Service $(text debug $service_name color_only) did exit with exit code $ec (failure), giving up"
          exit 1
        }
      }
    }

  }
done

text debug "Service container for service $(text debug $service_name color_only) will exit now"

# Reap zombies, if any
while kill %1 2>/dev/null; do
  # \o/ pure bash bible
  read -rt 0.1 <> <(:)||:
done
