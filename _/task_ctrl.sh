# These functions are sourced from within a service container and do not need any parameters
# Functions will read from the given environment of the service container

start_probe_job() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0) \
    with args $(join_array " " "${@}")"
  mapfile -t params < <(split "$probe" ":")
  probe_type=$(trim_string "${params[0]}")
  [[ "$probe_type" =~ http|tcp ]] || {
    text info "Service $service_colored has invalid probe type definition: $probe_type"
    kill -TERM -$$
  }
  trap -- "launched=1" SIGRTMIN

  env_ctrl "$service_name" "set" "active_probe_status" "2"
  env_ctrl "$service_name" "set" "active_probe_status_change" "$(printf "%(%s)T")"

  until [ -v launched ]; do
    delay 1
  done

  declare -i probe_counter=0
  if [[ $probe_type == "http" ]]; then
    text info "Service $service_colored probe (http) is now being tried"
    env_ctrl "$service_name" "set" "probe_type" "http"
    while true; do

      if [ ! -z "$(env_ctrl "$service_name" "get" "pending_signal")" ]; then
        delay $probe_interval
        continue
      fi

      if ! run_with_timeout $probe_timeout http_probe ${params[@]:1}; then
        ((probe_counter++))

        if [ $probe_counter -le $probe_retries ]; then
          text warning "Service $service_colored has a soft-failing HTTP probe [probe_retries=$((probe_counter-1))/${probe_retries}]"
        else
          [ "$(env_ctrl "$service_name" "get" "active_probe_status")" != "0" ] && {
            text error "Service $service_colored has a hard-failing HTTP probe"
            env_ctrl "$service_name" "set" "active_probe_status_change" "$(printf "%(%s)T")"
          }
          env_ctrl "$service_name" "set" "active_probe_status" "0"

          if [[ "$probe_failure_action" == "terminate" ]]; then
            >/tmp/bash-init-svc_${service_name}
            kill -TERM -$$

          elif [[ "$probe_failure_action" == "stop" ]]; then
            env_ctrl "$service_name" "set" "pending_signal" "stop"
            return

          elif [[ "$probe_failure_action" == "reload" ]]; then
            env_ctrl "$service_name" "set" "pending_signal" "reload"
            env_ctrl "$service_name" "set" "active_probe_status" "2"
            probe_counter=0

          elif [[ "$probe_failure_action" == "restart" ]]; then
            env_ctrl "$service_name" "set" "pending_signal" "restart"
            return
          fi
        fi
      else
        probe_counter=0
        [ "$(env_ctrl "$service_name" "get" "active_probe_status")" != "1" ] && {
          text success "HTTP probe for service $service_colored succeeded"
          env_ctrl "$service_name" "set" "active_probe_status_change" "$(printf "%(%s)T")"
        }
        env_ctrl "$service_name" "set" "active_probe_status" "1"
      fi
      [ $continous_probe -eq 0 ] && break
      delay $probe_interval
    done
  fi
}

prepare_container() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0) \
    with args $(join_array " " "${@}")"
  mapfile -t packages < <(. /tmp/bash-init-svc_${service_name} && split "$system_packages" ",")
  is_regex_match "$package_manager_lock_wait" "^[0-9]+$" || package_manager_lock_wait=600
  declare -i go=0 py=0
  declare -a py_pkgs go_pkgs

  if [ ! -z "${packages[@]}" ]; then
    for pkg in ${packages[@]}; do
      mapfile -t types < <(split "$pkg" ":")
      # Pathes may contain :, so ge 2 is fine
      [ ${#types[@]} -ge 2 ] && {
        [[ "${types[0]}" == "go" ]] && { go=1; go_pkgs+=("${types[@]:1}"); }
        [[ "${types[0]}" == "py" ]] && { py=1; py_pkgs+=("${types[1]}"); }
        packages=("${packages[@]/$pkg}")
      }
    done

    text info "Installing additional system packages for service ${service_colored}"
    if command -v apk >/dev/null; then
      [ $go -eq 1 ] && packages+=("go")
      [ $py -eq 1 ] && packages+=("python3" "py3-pip" "py3-virtualenv")
      apk --wait $package_manager_lock_wait add $(trim_all "${packages[@]}")
    elif command -v apt >/dev/null; then
      [ $go -eq 1 ] && packages+=("golang")
      [ $py -eq 1 ] && packages+=("python3" "python3-pip" "python3-virtualenv")
      apt -o DPkg::Lock::Timeout=$package_manager_lock_wait install $(trim_all "${packages[@]}")
    else
      text error "No supported package manager to install additional system packages"
      return 1
    fi

    for go_pkg in ${go_pkgs[@]}; do
      go install $go_pkg
    done

    if [ $py -eq 1 ]; then
      virtualenv --clear /virtualenvs/${service_name}
      source /virtualenvs/${service_name}/bin/activate
      pip3 install --upgrade pip
      pip3 install --upgrade $(trim_all "${py_pkgs[@]}")
    fi
  fi
}
