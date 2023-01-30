# These functions are sourced from within a service container and do not need any parameters
# Functions will read from the given environment of the service container

start_probe_job() {
  mapfile -t params < <(split "$probe" ":")
  probe_type=$(trim_string "${params[0]}")
  [[ "$probe_type" =~ http|tcp ]] || {
    text info "Service $service_colored has invalid probe type definition: $probe_type"
    kill -TERM -$$
  }
  trap -- "launched=1" SIGRTMIN

  printf "2" > runtime/probes/${probe_type}/${service_name}
  printf "%(%s)T" > runtime/messages/${service_name}.probe_change

  until [ -v launched ]; do
    sleep 1
  done

  declare -i probe_counter=0
  if [[ $probe_type == "http" ]]; then
    text info "Service $service_colored probe (http) is now being tried"
    printf "http" > runtime/messages/${service_name}.probe_type

    while true; do

      if [ -s runtime/messages/${service_name}.signal ]; then
        sleep $probe_interval
        continue
      fi

      if ! run_with_timeout $probe_timeout http_probe ${params[@]:1}; then
        ((probe_counter++))

        if [ $probe_counter -le $probe_retries ]; then
          text warning "Service $service_colored has a soft-failing HTTP probe [probe_retries=$((probe_counter-1))/${probe_retries}]"
        else
          [ $(<runtime/probes/http/${service_name}) -ne 0 ] && {
            text error "Service $service_colored has a hard-failing HTTP probe"
            printf "%(%s)T" > runtime/messages/${service_name}.probe_change
          }
          printf "0" > runtime/probes/http/${service_name}

          if [[ "$probe_failure_action" == "terminate" ]]; then
            cleanup_service_files ${service_name} 1 1 1
            kill -TERM -$$
          elif [[ "$probe_failure_action" == "stop" ]]; then
            printf "stop" > runtime/messages/${service_name}.signal
            return
          elif [[ "$probe_failure_action" == "reload" ]]; then
            printf "reload" > runtime/messages/${service_name}.signal
            probe_counter=0
          elif [[ "$probe_failure_action" == "restart" ]]; then
            printf "restart" > runtime/messages/${service_name}.signal
            return
          fi
        fi
      else
        probe_counter=0
        [ $(<runtime/probes/http/${service_name}) -ne 1 ] && {
          text success "HTTP probe for service $service_colored succeeded"
          printf "%(%s)T" > runtime/messages/${service_name}.probe_change
        }
        printf "1" > runtime/probes/http/${service_name}
      fi
      [ $continous_probe -eq 0 ] && break
      sleep $probe_interval
    done
  fi
}

prepare_container() {
  mapfile -t packages < <(. runtime/envs/${service_name} && split "$system_packages" ",")
  is_regex_match "$package_manager_lock_wait" "^[0-9]+$" || package_manager_lock_wait=600
  declare -i go=0 py=0
  declare -a py_pkgs go_pkgs

  if [ ${#packages[@]} -ne 0 ]; then
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
