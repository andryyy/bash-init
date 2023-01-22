text() {
  [ ${#@} -lt 2 ] && { text error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  local c
  local s
  case "${1}" in
    info) s=INFO; c=34;;
    warning) s=WARN; c=33;;
    error) s=ERROR; c=31;;
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
