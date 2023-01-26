. $env_file
. _/shared.sh

# Do not allow for new process groups when running $command
# This will prevent dedicated process groups and therefore zombie procs
# Also disallow file globbing
set -bf
set +m

service_colored=$(text debug $service_name color_only)

# ~ Subroutine
# Installation of additional system packages.
# This code block will be run when bootstrapping the service container
# and before launching the command.
(
mapfile -t packages < <(split "$system_packages" ",")
if [ ${#packages[@]} -ne 0 ]; then
  text info "Installing additional system packages for service ${service_colored}: $(trim_all "${packages[@]}")"
  if command -v apk >/dev/null; then
    apk --wait 30 add $(trim_all "${packages[@]}"); exit $?
  elif command -v apt >/dev/null; then
    apt install $(trim_all "${packages[@]}"); exit $?
  else
    text error "No supported package manager to install additional system packages"
    exit 1
  fi
fi
)& wait $! || {
  cleanup_service_files ${service_name}
  kill -TERM -$$
}

# ~ Subroutine
# Runs a probe in background job
# Waits for SIGRTMIN to launch
(
  [ ! -z "$probe" ] && {
    mapfile -t params < <(split "$probe" ":")
    probe_type=$(trim_string "${params[0]}")
    [[ "$probe_type" =~ http|tcp ]] || {
      text info "Service $service_colored has invalid probe type definition: $probe_type"
      exit 1
    }

    trap -- "launched=1" SIGRTMIN
    echo -1 > runtime/probes/${probe_type}/${service_name}
    declare -i probe_counter=0

    until [ -v launched ]; do
      sleep 1
    done

    text info "Service $service_colored probe (${probe_type}) is now being tried"

    while true; do
      if ! run_with_timeout $http_probe_timeout http_probe ${params[@]:1}; then
        ((probe_counter++))
        [ $probe_counter -le $probe_retries ] && {
          text warning "Service $service_colored has a soft-failing HTTP probe [probe_retries=$((probe_counter-1))/${probe_retries}]"
        } || {
          if [[ "$probe_failure_action" == "terminate" ]]; then
            text error "Service $service_colored terminates due to hard-failing HTTP probe"
            cleanup_service_files ${service_name}
            kill -TERM -$$
          else
            [ $(<runtime/probes/${probe_type}/${service_name}) -ne 0 ] && \
              text error "Service $service_colored has a hard-failing HTTP probe"
            echo 0 > runtime/probes/${probe_type}/${service_name}
          fi
        }
      else
        probe_counter=0
        [ $(<runtime/probes/${probe_type}/${service_name}) -ne 1 ] && \
          text success "HTTP probe for service $service_colored succeeded"
        echo 1 > runtime/probes/${probe_type}/${service_name}
      fi
      [ $continous_probe -eq 0 ] && break
      sleep $probe_interval
    done
  }
)&
http_probe_pid=$!

# Waiting for launch command
# This does also work when setting +m as we spawned this task in job control mode
kill -STOP $$

declare -i exit_ok=0
mapfile -t expected_exits < <(split "$success_exit" ",")

$command & pid=$!
# Start probes
kill -SIGRTMIN $http_probe_pid
# Wait for command
wait -f $pid

command_exit_code=$?
[[ $command_exit_code -ge 128 ]] && \
  text warning "Service $service_colored received a signal ($((command_exit_code-128))) from outside our control"

# Do nothing when bash-init is about to terminate
[ -f runtime/messages/${service_name}.terminate ] && {
  restart=""
}

# Check for success exit codes
for e in ${expected_exits[@]}; do
  regex_match "$e" "^[0-9]+$" && [[ $command_exit_code -eq $e ]] && exit_ok=1
done

# The command was executed, check how to handle restarts
# never
[[ "$restart" == "never" ]] && {
  [[ $exit_ok -eq 1 ]] && \
    text info "Service $service_colored did exit expected (${command_exit_code}) [restart=$restart]" || \
    text warning "Service $service_colored did exit unexpected (${command_exit_code}) [restart=$restart]"
}

# always|periodic
[[ "$restart" =~ always|periodic ]] && {
  text info "Service $service_colored did exit with code $command_exit_code [restart=$restart]"
  kill -TERM -$$
}

# on-failure
[[ "$restart" == "on-failure" ]] && {
  [[ $exit_ok -eq 1 ]] && {
    text info "Service $service_colored did exit expected (${command_exit_code}) [restart=$restart]"
  } || {
    text warning "Service $service_colored did exit unexpected (${command_exit_code}) [restart=$restart]"
    kill -TERM -$$
  }
}

text info "Self-destroying service container (process group $$) of service $service_colored now"
cleanup_service_files ${service_name}
kill -TERM -$$
