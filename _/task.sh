. $env_file
. _/system.sh
. _/tools.sh
. _/task_ctrl.sh

# Cleanup probes and messages
cleanup_service_files $service_name 0 1 1

# Do not allow for new process groups when running $command
# This will prevent dedicated process groups and therefore zombie procs
# Also disallow file globbing
set -bf
set +m

service_colored=$(text debug $service_name color_only)

# Installation of additional system packages.
install_packages ${service_name} || {
  cleanup_service_files $service_name 1 1 1
  kill -TERM -$$
}
[ -d ~/go/bin/ ] && PATH=${PATH}:~/go/bin
[ -d /virtualenvs/${service_name}/bin ] && PATH=${PATH}:/virtualenvs/${service_name}/bin

# ~ Subroutine
# Runs a probe in background job
# Waits for SIGRTMIN to launch
if [ ! -z "$probe" ]; then
  start_probe_job &
  probe_pid=$!
fi

# Waiting for launch command
# This does also work when setting +m as we spawned this task in job control mode
kill -STOP $$

declare -i exit_ok=0
mapfile -t expected_exits < <(split "$success_exit" ",")

if [ $probe_as_dependency -eq 1 ]; then
  [ -v probe_pid ] && {
    kill -SIGRTMIN $probe_pid
  }
  until [ -f runtime/messages/${service_name}.probe_type ]; do
    sleep 0.1
  done
  probe_type=$(<runtime/messages/${service_name}.probe_type)
  if regex_match "$probe_type" "(http|tcp)"; then
    until [ -f runtime/probes/${probe_type}/${service_name} ] && [ $(<runtime/probes/${probe_type}/${service_name}) -eq 1 ]; do
      text info "Service container $service_colored is awaiting healthy probe"
      sleep 3
    done
  fi
  $command & pid=$!
else
  $command & pid=$!
  [ -v probe_pid ] && {
    kill -SIGRTMIN $probe_pid
  }
fi
wait -f $pid

command_exit_code=$?
[[ $command_exit_code -ge 128 ]] && \
  text warning "Service $service_colored received a signal ($((command_exit_code-128))) from outside our control"

# Do nothing when bash-init is about to stop this service
[ -f runtime/messages/${service_name}.stop ] && {
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
cleanup_service_files $service_name 1 1 1
kill -TERM -$$
