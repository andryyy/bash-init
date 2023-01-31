. $env_file
. _/system.sh
. _/tools.sh
. _/task_ctrl.sh

# Do not allow for new process groups when running $command
# This will prevent dedicated process groups and therefore zombie procs
# Also disallow file globbing
set -bf
set +m

service_colored=$(text info $service_name color_only)

# Installation of additional system packages.
prepare_container ${service_name} || {
  >/tmp/bash-init-svc_${service_name}
  kill -TERM -$$
}
[ -d ~/go/bin/ ] && PATH=${PATH}:~/go/bin
# virtualenv is enabled in prepare_container, too
[ -d /virtualenvs/${service_name}/bin ] && source /virtualenvs/${service_name}/bin/activate

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
if [ -v probe_pid ] && [ $probe_as_dependency -eq 1 ]; then
  kill -SIGRTMIN $probe_pid
  until [ "$(env_ctrl "$service_name" "get" "active_probe_status")" == "1" ]; do
    text info "Service container $service_colored is awaiting healthy probe"
    sleep 3
  done
  $command & command_pid=$!
else
  $command & command_pid=$!
  [ -v probe_pid ] && {
    kill -SIGRTMIN $probe_pid
  }
fi

env_ctrl "$service_name" "set" "command_pid" "$command_pid"
env_ctrl "$service_name" "set" "container_pid" "$$"
[ -v probe_pid ] && env_ctrl "$service_name" "set" "probe_pid" "$probe_pid"

text success "[Stage 3/3] Service container $service_colored ($$) started command with PID $command_pid"
wait -f $command_pid

command_exit_code=$?
[[ $command_exit_code -ge 128 ]] && \
  text warning "Service $service_colored received a signal ($((command_exit_code-128))) from outside our control"

# Do nothing when bash-init is about to stop this service
[ ! -z "$(env_ctrl "$service_name" "get" "pending_signal")" ] && {
  restart=""
}

# Check for success exit codes
for e in ${expected_exits[@]}; do
  is_regex_match "$e" "^[0-9]+$" && [[ $command_exit_code -eq $e ]] && exit_ok=1
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
>/tmp/bash-init-svc_${service_name}
kill -TERM -$$
