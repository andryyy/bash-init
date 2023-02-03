![full_colored_dark | width=256](https://user-images.githubusercontent.com/2972950/216524472-0b9d50fb-6b36-41e2-8ce0-fa84a537fc45.svg)

# bash-init

Pure bash init system, a work in progress.

No coreutils, just bash.

![screenshot](https://user-images.githubusercontent.com/2972950/216527938-3cd07b6f-e9c5-4d9a-8176-04ef785babfd.png)

- Dedicated process groups per service container for proper signal handling
  - Commands and jobs in containers will re-use the service containers process group
- Messaging via environment files per service
- Dependencies
- Periodic commands
- Auto-installation of system packages (Alpine, Debian)
  - Auto-setup of Python virtual envs if package name is "py:name"
  - Auto-installation of Go packages when package name is "go:name"
- Health checks (HTTP probes)
- Restart policies
- Service container stats
- Custom reload signals (properly sent to command PID only)
- Custom stop signals (sent to a service containers process group)
- No zombies 🧟‍♂️

Documentation soon. Really. I'm serious.

**Todo**

- Documentation
- Specify UID/GID (auto-setup of users if missing)
- Isolation (will most likely require non-bash dependencies)
  - Chroot/Container/Cgroups
- Restricted bash for service commands
- Validate configuration parameter types
- CPU usage
  - Read CPU ticks in a fixed time frame and put it in reference to CONFIG_HZ
- Detect dependency loops
- Write tests
- Allow custom headers for HTTP probes
- Implement send/expect TCP probes
- Write notifiers
- Do not use "text" in functions but use general lang files according to return codes
  - funcname[$return_code]="string"
