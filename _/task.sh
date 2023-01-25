. $env_file
. _/shared.sh
# Do not allow for new process groups when running $command
# This will prevent dedicated process groups and therefore zombie procs
# Also disallow file globbing
set -bf
set +m
#exec &> /dev/stdout 2>&1

service_colored=$(text debug $service_name color_only)

# Install additional packages
mapfile -t packages < <(split "$system_packages" ",")
[ ${#packages[@]} -ne 0 ] && {
  # todo: read from proc
  [[ $(id -u) -ne 0 ]] && {
    text error "Cannot install packages for service $service_colored as non-root user"
    rm runtime/${service_name}.env
    kill -TERM -$$
  }
  text info "Installing additional system packages for service ${service_colored}: $(trim_all "${packages[@]}")"
  if command -v apk >/dev/null; then
    apk --wait 30 add $(trim_all "${packages[@]}")
  elif command -v apt >/dev/null; then
    apt install $(trim_all "${packages[@]}")
  else
    text error "Cannot install additional system packages for service $service_colored"
  fi ;
}

# Run probes
declare -i i=0
[ ! -z "$probe" ] && {
  mapfile -t params < <(split "$probe" ":")
  while ! run_with_timeout $http_probe_timeout http_probe ${params[@]:1}; do
    ((i++))
    [ $i -lt $probe_retries ] && {
      text warning "Service $service_colored has an unmet HTTP probe (${i}/${probe_retries})"
      read -rt $i <> <(:)||:
    } || {
      text error "Service $service_colored terminates due to unmet HTTP probe"
      kill -TERM -$$
    }
  done
  text success "HTTP probe for service $service_colored succeeded"
}

# Waiting for launch command
# This does also work when setting +m as we spawned this task in job control mode
kill -STOP $$

declare -i i=0
declare -i exit_ok=0
mapfile -t expected_exits < <(split "$success_exit" ",")

$command &
wait -f $!
command_exit_code=$?
[[ $command_exit_code -ge 128 ]] && \
  text warning "Service $service_colored received a signal ($((command_exit_code-128))) from outside our control"

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
rm runtime/${service_name}.env
kill -TERM -$$
