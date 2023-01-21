text() {
  [ ${#@} -lt 2 ] && { color_text red error "${FUNCNAME[0]}: Invalid arguments"; return 1; }
  local c
  local s
  case "${1}" in
    info) s=INFO; c=34;;
    warn) s=WARN; c=33;;
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
