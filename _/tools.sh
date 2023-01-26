text() {
  [ ${#@} -lt 2 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  local c
  local s
  local t
  case "${1}" in
    info) s=INFO; c=96;;
    success) s=SUCCESS; c=32;;
    warning) s=WARN; c=33;;
    error) s=ERROR; c=31;;
    stats) s=STATS; c=35;;
    *) s=DEBUG; c=94;;
  esac
  shift
  t=$(trim_all "$1")
  [[ "${!#}" == "color_only" ]] && {
    printf "\e[%sm%s\e[0m\n" "$c" "${@:1:${#}-1}"
  } || {
    printf "\e[%sm%8s\e[0m %s\n" "$c" "$s" "$t"
  }
}

join_array() {
  # join $2 by $1
  local d=${1-} f=${2-}
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

# \o/ pure bash bible
split() {
  # split $1 by $2
  IFS=$'\n' read -d "" -ra arr <<< "${1//$2/$'\n'}"
  printf '%s\n' "${arr[@]}"
}

# \o/ pure bash bible
trim_all() {
  set -f
  set -- $*
  printf '%s\n' "$*"
  set +f
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

run_with_timeout () {
  declare -i time=3
  regex_match "$1" "^[0-9]+$" && { time=$1; shift; }
  (
    "$@" &
    child=$!
    (
      sleep $time
      kill $child 2> /dev/null
    ) &
    wait $child
  )
}
