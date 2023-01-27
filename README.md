# bash-init

Pure bash init system, a work in progress.

Documentation soon (tm).

**Todo**

- Indicate probe health with RT signals
- Use signals or file descriptors for messages
- Re-evaluate read as replacement for sleep (this does for some reason defunct bash while reading)
- Try not to use rm (temp files or fd?)
- Write tests
- Do not use "text" in functions but use general lang files according to return codes
  - funcname[$return_code]="string"
- Stats as JSON