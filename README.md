# bash-init

Pure bash init system, a work in progress.

Documentation soon (tm).

**Todo**

- Validate configuration
- Detect dependency loops
- Use signals or file descriptors for messages
- Re-evaluate read as replacement for sleep (this does for some reason defunct bash while reading)
- Try not to use rm (temp files or fd?)
- Write tests
- Do not use "text" in functions but use general lang files according to return codes
  - funcname[$return_code]="string"

# Runtime

## Service messages

**Location**: `runtime/messages`

Contains files in the format of `$service.$action`.

A service message file may contain information to be used when picked up by the main process.

**1\.** `$service.signal` - Indicates a service should be stopped or restarted.

- A service container will not read the content but skip any self-controlled restart mechanisms when the message file exists.
This prevents the service from restarting automatically when it is sent a stop signal by the parent PID.
The _main process_ will pick up the file and read the stop_service policy.

- Required content: stop|restart|reload

**2\.** `$service.probe_type` - Contains the currently active probe type for a service.

- Required content: http|tcp

**3\.** `$service.probe_change` - Contains the last probe state change.

- Required content: unix timestamp

**4\.** `$service.command_pid` - Contains the PID of the command inside a service container

- Required content: pid

