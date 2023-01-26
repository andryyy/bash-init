. $env_file
. _/system.sh
. _/tools.sh
. _/task_ctrl.sh

# Cleanup previous messages
# Do not run cleanup_service_files as it will wipe all service files
rm -f runtime/messages/${service_name}.*

# Do not allow for new process groups when running $command
# This will prevent dedicated process groups and therefore zombie procs
# Also disallow file globbing
set -bf
set +m

service_colored=$(text debug $service_name color_only)

# Installation of additional system packages.
install_packages ${service_name} || {
  cleanup_service_files $service_name
  kill -TERM -$$
}

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

$command & pid=$!
# Start probes
[ -v probe_pid ] && {
  kill -SIGRTMIN $probe_pid
}
# Wait for command
wait -f $pid

command_exit_code=$?
[[ $command_exit_code -ge 128 ]] && \
  text warning "Service $service_colored received a signal ($((command_exit_code-128))) from outside our control"

# Do nothing when bash-init is about to terminate
[ -f runtime/messages/${service_name}.no_restart ] && {
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
cleanup_service_files $service_name
kill -TERM -$$
