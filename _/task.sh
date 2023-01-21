. $env_file
. _/shared.sh
exec &> /dev/stdout 2>&1
trap "stop=1" USR1
# Waiting for launch command
kill -STOP $$
i=0
while true && [ ! -v stop ]; do
  eval $command
  ec=$?
  [ ! -v stop ] && {
    [[ "$restart" =~ (always|periodic) ]] && {
      text info "Service $service_name did return exit code $ec"
    } || [[ "$restart" == "never" ]] && {
      text error "Service $service_name did exit with exit code $ec, not restarting due to restart policy"
      break
    } || [[ "$restart" == "on-failure" ]] && {
      [[ $ec -eq 0 ]] && {
        text info "Service $service_name did exit with exit code $ec (not a failure), not restarting"
        break
      } || {
        [ $i -lt $restart_retries ] && {
          ((i++))
          text danger "Service $service_name did exit with exit code $ec (failure), restarting (${i}/${restart_retries}"
        } || exit 1
      }
    }
  }
done

while kill %1 2>/dev/null; do
  sleep 0.1
done
