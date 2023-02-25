<img src="https://user-images.githubusercontent.com/2972950/216524472-0b9d50fb-6b36-41e2-8ce0-fa84a537fc45.svg" width="256">

# bash-init

Pure Bash init system, a work in progress.

No coreutils, just Bash.

![screenshot](https://user-images.githubusercontent.com/2972950/216527938-3cd07b6f-e9c5-4d9a-8176-04ef785babfd.png)

- Dedicated process groups per service container for proper signal handling
  - Commands and jobs in containers will re-use the service containers process group
- Messaging via environment files per service
- Dependencies
- Periodic commands
- Auto-installation of system packages (Alpine, Debian)
  - Auto-setup of Python virtualenvs if package name is "py:name"
  - Auto-installation of Go packages when package name is "go:name"
- Health checks (HTTP and TCP probes)
- Restart policies
- Service container stats
- Custom reload signals (properly sent to command PID only)
- Custom stop signals (sent to a service containers process group)
- Run service as uid:gid
- Prepend stdout/stderr of each service for a better overview
- No zombies 🧟‍♂️

Running a service with a predefined uid/gid will auto-install su-exec resp. gosu.
For Python services that also have the `runas` parameter defined, bash-init requires "chown" to set proper permissions in the virtualenv.

Documentation soon. Really. I'm serious.

**Todo**

- Documentation
- Isolation (will most likely require non-bash dependencies)
  - Chroot/Container/Cgroups
- Restricted bash for service commands
- Validate configuration parameter types
- CPU usage
  - Read CPU ticks in a fixed time frame and put it in reference to CONFIG_HZ
- Write tests
- Write notifiers
- Do not use "text" in functions but use general lang files according to return codes
  - funcname[$return_code]="string"

## Quick start

### Considerations

There are two limiting factors to be taken into consideration when chosing the correct base system or container environment for bash-init.

**1\. The package manager**

This limitation only exists for setups that make use of the `system_packages` parameter.
If you don't plan to let bash-init install system, Go, or Python packages, this limitation is not a problem for you.

bash-init can handle **"apt"** (Debian and derivates) as well as **"apk"** (Alpine) for installing system packages, Python environments, and Go packages.

**2\. Dropping privileges**

If you plan to use the `runas` parameter, and that's something you most likely will do, again, the environment must be Debian or Alpine based.

For **Python services** that have the `runas` parameter defined, bash-init also requires "chown" to set proper permissions on the virtualenv.
There is not yet an easy workaround for this, as much as I would love to drop this "requirement".

That's not something to worry about; even in the smallest Bash-focused container images available, there will always be a minimal busybox setup that provides the "chown" command. It is a problem of cosmetic nature, after all.

---

When run containerized, [the official Bash image](https://hub.docker.com/_/bash) works perfectly fine.

### Bash requirement

Your base system should provide a Bash in version >=5.

