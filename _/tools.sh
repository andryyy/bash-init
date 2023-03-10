text() {
  [ ${#@} -lt 2 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  local c
  local s
  local t
  case "$1" in
    info) s=INFO; c=96;;
    success) s=SUCCESS; c=32;;
    warning) s=WARN; c=93;;
    error) s=ERROR; c=31;;
    stats) s=STATS; c=35;;
    *) s=DEBUG; c=94;;
  esac
  shift
  t=$(trim_all "$1")
  [[ "${!#}" == "color_only" ]] && {
    printf "\e[%sm%s\e[0m\n" "$c" "${@:1:${#}-1}"
  } || {
    printf '%(%c)T ' -1
    printf "\e[%sm%8s\e[0m %s\n" "$c" "$s" "$t"
  }
}

stage() {
  [ ${#@} -ne 2 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  fc=97
  case "$1" in
    info) c=46;;
    success) c=42;;
    warning) c=103; fc=30;;
    error) c=41;;
  esac
  shift
  case "$1" in
    1) printf "|\e[1;%d;%dm Sta\e[0;47;30mge 1/3 \e[0m|" "$c" "$fc";;
    2) printf "|\e[1;%d;%dm Stage \e[0;47;30m2/3 \e[0m|" "$c" "$fc";;
    3) printf "|\e[1;%d;%dm Stage 3/3 \e[0m|" "$c" "$fc";;
  esac
}

probe_text() {
  [ ${#@} -ne 1 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  fc=97
  case "$1" in
    info) c=46;;
    success) c=42;;
    warning) c=103; fc=30;;
    error) c=41;;
  esac
  printf "|\e[1;%d;%dm Probe \e[0m|" "$c" "$fc"
  case "$1" in
    1) c=46;;
    2) c=42;;
    3) c=103; fc=30;;
    error) c=41;;
  esac
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

is_regex_match() {
  [[ $1 =~ $2 ]]
}

run_with_timeout () {
  declare -i time=3
  is_regex_match "$1" "^[0-9]+$" && { time=$1; shift; }
  (
    "$@" &
    child=$!
    (
      delay $time
      kill $child 2> /dev/null
    ) &
    wait $child
  )
}

delay() (
  trap "kill ${COPROC_PID} 2>/dev/null" INT TERM
  declare i=$1
  coproc {
    read -n1 -s -t$i
  }
  wait $!
)

print_regex_match() {
  [[ $1 =~ $2 ]] && printf '%s\n' "${BASH_REMATCH[1]}" || return 0
}

print_all_regex_matches() {
  [[ $1 =~ $2 ]]
  for match in "${BASH_REMATCH[@]:1}"; do
    printf '%s\n' $match
  done
}
