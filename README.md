# bash-init

Pure bash init system, a work in progress.

No coreutils, just bash.

- Dependencies
- Periodic commands
- Auto-install system packages (Alpine, Debian)
  - Auto-setup of Python virtual envs if package name is "py:name"
  - Auto-installation of Go packages when package name is "go:name"
- Health checks (HTTP probes)
- Restart policies
- Service container stats
- Custom reload signals
- Custom stop signals
- No zombies 🧟‍♂️

Documentation soon. Really. I'm serious.

**Todo**

- Documentation
- Specify UID/GID (auto-setup of users if missing)
- Isolation (will most likely require non-bash dependencies)
  - Chroot/Container/Cgroups
- Restricted bash for service commands
- Validate configuration parameter type
- Detect dependency loops
- Write tests
- Allow custom headers for HTTP probes
- Implement send/expect TCP probes
- Write notifiers
- Do not use "text" in functions but use general lang files according to return codes
  - funcname[$return_code]="string"
