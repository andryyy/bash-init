docker run --rm --name bash-init \
  -v $(pwd):/bash-init \
  --stop-timeout=600 \
  --pids-limit=200 \
  -p 8000:8000 \
  bash /bash-init/run.sh ${@}
