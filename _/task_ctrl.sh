# These functions are sourced from within a service container and do not need any parameters
# Functions will read from the given environment of the service container

start_probe_job() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0) \
    with args $(join_array " " "${@}")"
  mapfile -t params < <(split "$probe" ":")
  probe_type=$(trim_string "${params[0]}")
  if ! [[ "${probe_type,,}" =~ http|tcp ]]; then
    text info "Service $service_colored has invalid probe type definition: $probe_type"
    env_ctrl "$service_name" "set" "pending_signal" "stop"
    return
  fi

  trap -- "launched=1" SIGRTMIN

  env_ctrl "$service_name" "set" "active_probe_status" "2"
  env_ctrl "$service_name" "set" "active_probe_status_change" "$(printf "%(%s)T")"
  env_ctrl "$service_name" "set" "probe_type" "$probe_type"

  until [ -v launched ]; do
    delay 1
  done

  declare -i probe_counter=0
  text info "$(probe_text info) Service $service_colored probe (${probe_type^^}) is now being tried"

  while true; do
    if [ ! -z "$(env_ctrl "$service_name" "get" "pending_signal")" ]; then
      return 1
    fi

    if [[ "${probe_type,,}" == "http" ]]; then
      run_with_timeout $probe_timeout ${probe_type,,}_probe ${params[@]:1} "$http_probe_headers"
      ec=$?
    elif [[ "${probe_type,,}" == "tcp" ]]; then
      run_with_timeout $probe_timeout ${probe_type,,}_probe ${params[@]:1}
      ec=$?
    fi

    if [ $ec -ne 0 ]; then
      ((probe_counter++))

      if [ $probe_counter -le $probe_retries ]; then
        text warning "$(probe_text warning) Service $service_colored has a soft-failing ${probe_type^^} probe [probe_retries=$((probe_counter-1))/${probe_retries}]"
      else
        if [ "$(env_ctrl "$service_name" "get" "active_probe_status")" != "0" ]; then
          text error "$(probe_text error) Service $service_colored has a hard-failing ${probe_type^^} probe"
          env_ctrl "$service_name" "set" "active_probe_status_change" "$(printf "%(%s)T")"
          env_ctrl "$service_name" "set" "active_probe_status" "0"
        fi

        if [[ "$probe_failure_action" == "stop" ]]; then
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
      if [ "$(env_ctrl "$service_name" "get" "active_probe_status")" != "1" ]; then
        text success "$(probe_text success) ${probe_type^^} probe for service $service_colored succeeded"
        env_ctrl "$service_name" "set" "active_probe_status_change" "$(printf "%(%s)T")"
        env_ctrl "$service_name" "set" "active_probe_status" "1"
      fi
    fi
    [ $continous_probe -eq 0 ] && break
    delay $probe_interval
  done
}

prepare_container() {
  [ -v debug ] && text debug "Function ${FUNCNAME[0]} called by $(caller 0) \
    with args $(join_array " " "${@}")"
  mapfile -t packages < <(. /tmp/bash-init-svc_${service_name} && split "$system_packages" ",")

  if [ ! -z "$runas" ]; then
    mapfile -t runas_test < <(split "$runas" ":")
    if [ ${#runas_test[@]} -ne 2 ]; then
      text error "$(stage error 2) Service $service_colored has an invalid runas specification"
      exit 1
    fi

    for k in ${runas_test[@]}; do
      if ! is_regex_match "$k" "^[0-9]+$"; then
        text error "$(stage error 2) Service $service_colored has an invalid runas specification"
        exit 1
      fi
    done

    [ -v debian ] && { packages+=("gosu"); }
    [ -v alpine ] && { packages+=("su-exec"); }
  fi

  declare -i go=0 py=0
  declare -a py_pkgs go_pkgs

  if [ ! -z "${packages}" ]; then
    if [ -v debian ]; then
      apt update
    fi

    for pkg in ${packages[@]}; do
      mapfile -t types < <(split "$pkg" ":")
      # Pathes may contain :, so ge 2 is fine
      [ ${#types[@]} -ge 2 ] && {
        [[ "${types[0]}" == "go" ]] && { go=1; go_pkgs+=("${types[@]:1}"); }
        [[ "${types[0]}" == "py" ]] && { py=1; py_pkgs+=("${types[1]}"); }
        packages=("${packages[@]/$pkg}")
      }
    done

    [ -v debug ] && exec 3>&1 || exec 3>/dev/null
    text info "$(stage info 2) Installing additional system packages for service $service_colored"
    if [ -v alpine ]; then
      [ $go -eq 1 ] && packages+=("go")
      [ $py -eq 1 ] && packages+=("python3" "py3-pip" "py3-virtualenv")
      apk --wait $package_manager_lock_wait add $(trim_all "${packages[@]}") >&3
    elif [ -v debian ]; then
      [ $go -eq 1 ] && packages+=("golang")
      [ $py -eq 1 ] && packages+=("python3" "python3-pip" "python3-virtualenv")
      apt -o DPkg::Lock::Timeout=$package_manager_lock_wait install $(trim_all "${packages[@]}") >&3
    else
      text error "$(stage error 2) No supported package manager to install additional system packages"
      return 1
    fi

    for go_pkg in ${go_pkgs[@]}; do
      text info "$(stage info 2) Installing go package $go_pkg for service container $service_colored"
      go install $go_pkg >&3
    done

    if [ $py -eq 1 ]; then
      text info "$(stage info 2) Setting up Python environment for packages $(trim_all "${py_pkgs[@]}") in service container $service_colored"

      virtualenv ${python_virtualenv_clear} /virtualenvs/${service_name} >&3
      source /virtualenvs/${service_name}/bin/activate >&3
      pip3 install --upgrade pip >&3
      pip3 install --upgrade $(trim_all "${py_pkgs[@]}") >&3

      if [ ! -z "$runas" ]; then
        chown -R $runas /virtualenvs/${service_name}
      fi
    fi

    exec 3>&-
  fi
}

#---------------------------#
#--------- Stage 3 ---------#
#---------------------------#
# Starts probe and runs command
# Returns command_pid
run_command() {
  # Allow for last-minute command changes
  local command=$(env_ctrl "$service_name" "get" "command")

  # Add prefix to service stdout and stderr by using a named pipe
  prefix() {
    s=$1
    shift
    local line
    while read line; do
      printf '%(%c)T ' -1
      printf "\e[1m%8s\e[0m [service=%s] >> %s\n" "$s" "$service_name" "$line"
    done
  }

  exec {fd1}> >(prefix STDOUT)
  exec {fd2}> >(prefix STDERR)

  if [ -v probe_pid ] && [ $probe_as_dependency -eq 1 ]; then
    kill -SIGRTMIN $probe_pid
    declare -i probe_status_loop=0
    until [ "$(env_ctrl "$service_name" "get" "active_probe_status")" == "1" ]; do
      ((probe_status_loop++))
      [ $((probe_status_loop%3)) -eq 0 ] && \
        text warning "$(stage warning 3) Service container $service_colored is awaiting healthy probe to run command"
      delay 1
    done
    local start_probe=0
  else
    local start_probe=1
  fi

  if [ ! -z "$runas" ]; then
    $runas_helper $runas $command 1>&$fd1 2>&$fd2 & command_pid=$!
  else
    $command 1>&$fd1 2>&$fd2 & command_pid=$!
  fi

  [ -v probe_pid ] && [ $start_probe -eq 1 ] && kill -SIGRTMIN $probe_pid
  env_ctrl "$service_name" "set" "command_pid" "$command_pid"
  text success "$(stage success 3) Service container $service_colored ($$) started command with PID $command_pid"
}
