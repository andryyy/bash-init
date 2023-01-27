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
  echo -1 > runtime/probes/http/${service_name}

  until [ -v launched ]; do
    sleep 1
  done

  declare -i probe_counter=0
  if [[ $probe_type == "http" ]]; then
    text info "Service $service_colored probe (http) is now being tried"
    while true; do
      if ! run_with_timeout $http_probe_timeout http_probe ${params[@]:1}; then
        ((probe_counter++))
        if [ $probe_counter -le $probe_retries ]; then
          text warning "Service $service_colored has a soft-failing HTTP probe [probe_retries=$((probe_counter-1))/${probe_retries}]"
        else
          if [[ "$probe_failure_action" == "terminate" ]]; then
            text error "Service $service_colored terminates due to hard-failing HTTP probe NOW"
            cleanup_service_files ${service_name} 1 1 1
            kill -TERM -$$
          elif [[ "$probe_failure_action" == "stop" ]]; then
            text error "Service $service_colored is queued to be stopped by failing HTTP probe"
            echo stop > runtime/messages/${service_name}.stop
          elif [[ "$probe_failure_action" == "restart" ]]; then
            text error "Service $service_colored is queued to be restarted by failing HTTP probe"
            echo restart > runtime/messages/${service_name}.stop
          else
            [ $(<runtime/probes/http/${service_name}) -ne 0 ] && \
              text error "Service $service_colored has a hard-failing HTTP probe"
            echo 0 > runtime/probes/http/${service_name}
          fi
        fi
      else
        probe_counter=0
        [ $(<runtime/probes/http/${service_name}) -ne 1 ] && \
          text success "HTTP probe for service $service_colored succeeded"
        echo 1 > runtime/probes/http/${service_name}
      fi
      [ $continous_probe -eq 0 ] && break
      sleep $probe_interval
    done
  fi
}

install_packages() {
  mapfile -t packages < <(. runtime/envs/${service_name} && split "$system_packages" ",")
  regex_match "$package_manager_lock_wait" "^[0-9]+$" || package_manager_lock_wait=600
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
      pip3 install $(trim_all "${py_pkgs[@]}")
    fi
  fi
}
