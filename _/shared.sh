text() {
  [ ${#@} -lt 2 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  local c
  local s
  case "${1}" in
    info) s=INFO; c=34;;
    success) s=GOOD; c=32;;
    warning) s=WARN; c=33;;
    error) s=BAD; c=31;;
    *) s=DEBUG; c=96;;
  esac
  shift
  [[ "${!#}" == "color_only" ]] && {
    printf "\e[%sm%s\e[0m\n" "$c" "${@:1:${#}-1}"
  } || {
    printf "\e[%sm[%s]\e[0m %s\n" "$c" "$s" "$1"
  }
}

# \o/ pure bash bible
split() {
  # split $1 by $2
  IFS=$'\n' read -d "" -ra arr <<< "${1//$2/$'\n'}"
  printf '%s\n' "${arr[@]}"
}

# \o/ pure bash bible
trim_string() {
  : "${1#"${1%%[![:space:]]*}"}"
  : "${_%"${_##*[![:space:]]}"}"
  printf '%s' "$_"
}

regex_match() {
  [[ $1 =~ $2 ]]
}

http_probe() {
  # http_probe hostname port path method expected_status_code
  # Example: http_probe www.example.com 80 "/" GET 200
  # Should be called with run_with_timeout to avoid long waits
  [ ${#@} -ne 5 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  local host
  local status_code
  local method
  local path
  declare -i port
  declare -i status_code
  host=$(trim_string "$1")
  port="$2"
  path=$(trim_string "$3")
  method=$(trim_string "$4")
  status_code="$5"
  [ $status_code -eq 0 ] && status_code=200
  [ $port -eq 0 ] && port=80
  exec 3<>/dev/tcp/${host}/${port}
  printf "%s %s HTTP/1.1\r\nhost: %s\r\nConnection: close\r\n\r\n" "$method" "$path" "$host" >&3
  mapfile -t response <&3
  regex_match "${response[0]}" "$(printf "HTTP/1.1 %s" "${status_code}")" && return 0
  return 1
}

# https://stackoverflow.com/a/24413646
run_with_timeout () {
  declare -i time=3
  regex_match "$1" "^[0-9]+$" && { time=$1; shift; }
  (
    "$@" &
    child=$!
    (
      read -rt $time <> <(:)||:
      kill $child 2> /dev/null
    ) &
    wait $child
  )
}
