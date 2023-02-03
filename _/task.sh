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
prepare_container "$service_name" || {
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

# command_pid will be set in run_command function
env_ctrl "$service_name" "set" "container_pid" "$$"
[ ! -z "$probe" ] && env_ctrl "$service_name" "set" "probe_pid" "$probe_pid"

# Waiting for launch command
# This does also work when setting +m as we spawned this task in job control mode
kill -STOP $$

declare -i exit_ok=0
mapfile -t expected_exits < <(split "$success_exit" ",")

# We may have been configured to self-destroy in the time we slept (STOP)
while [ -z "$(env_ctrl "$service_name" "get" "pending_signal")" ]; do
  start_time=$(printf "%(%s)T")

  run_command

  if [ -z "$periodic_interval" ]; then
    wait -f $command_pid
    command_exit_code=$?
    break
  fi

  until [ $(( $(printf "%(%s)T") - $start_time)) -ge $periodic_interval ]; do
    if ! proc_exists $command_pid; then
      text success "Service $service_colored periodic command did complete"
      passed_time=$(( $(printf "%(%s)T") - $start_time ))
      delay $(( $periodic_interval - $passed_time ))
      break
    fi
    delay 1
  done

  if proc_exists $command_pid; then
    text warning "Service $service_colored periodic command did not stop in time, queuing restart"
    env_ctrl "$service_name" "set" "pending_signal" "restart"
  fi

done

[[ $command_exit_code -ge 128 ]] && \
  text warning "Service $service_colored command received a signal \
    ($((command_exit_code-128))) from outside our control or terminated on a reload signal"

# Check for success exit codes
for e in ${expected_exits[@]}; do
  is_regex_match "$e" "^[0-9]+$" && [[ $command_exit_code -eq $e ]] && exit_ok=1
done

# Do nothing when bash-init decided for an action
pending_signal="$(env_ctrl "$service_name" "get" "pending_signal")"
if [ -z "$pending_signal" ]; then

  if [[ "$restart" == "never" ]]; then
    if [[ $exit_ok -eq 1 ]]; then
      text info "Service $service_colored did exit expected (${command_exit_code}) [restart=$restart]"
    else
      text warning "Service $service_colored did exit unexpected (${command_exit_code}) [restart=$restart]"
    fi
    env_ctrl "$service_name" "set" "pending_signal" "stop"

  elif [[ "$restart" == "always" ]]; then
    text info "Service $service_colored did exit with code $command_exit_code [restart=$restart]"
    env_ctrl "$service_name" "set" "pending_signal" "restart"

  elif [[ "$restart" == "on-failure" ]]; then
    if [[ $exit_ok -eq 1 ]]; then
      text info "Service $service_colored did exit expected (${command_exit_code}) [restart=$restart]"
      env_ctrl "$service_name" "set" "pending_signal" "stop"
    else
      text warning "Service $service_colored did exit unexpected (${command_exit_code}) [restart=$restart]"
      env_ctrl "$service_name" "set" "pending_signal" "restart"
    fi

  else
    text info "Service $service_colored has no valid restart policy, stopping"
    env_ctrl "$service_name" "set" "pending_signal" "stop"
  fi

else
  text info "Pending signal for service $service_colored [pending_signal=$pending_signal] (process group $$)"
fi

text info "Awaiting signal execution for service container (process group $$) of service $service_colored"

while :; do delay 1; done
