# bash-init

Pure bash init system, a work in progress.

Documentation soon (tm).

**Todo**

- Validate configuration
- Detect dependency loops
- Re-evaluate read as replacement for sleep (this does for some reason defunct bash while reading)
- Write tests
- Do not use "text" in functions but use general lang files according to return codes
  - funcname[$return_code]="string"
