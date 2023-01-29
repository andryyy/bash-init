# A subshell with a piped stdin at ${channel[1]} and stdout at ${channel[0]}
create_com_chan() {
  coproc channel {
    while true; do
      read -r -e -u 0 line
      echo "${line}"
    done
  }
  comm_chan=/proc/1/fd/${channel[1]}
  text debug "Communication channel is at $comm_chan"

  while true; do
    read s <"/proc/1/fd/${channel[0]}" || break
    text debug "Communication channel: $s"
  done &
}
