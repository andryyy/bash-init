docker run --rm --name bash-init \
  -v $(pwd):/bash-init \
  --stop-timeout=600 \
  --pids-limit=200 \
  -p 8080:8080 \
  -p 8081:8081 \
  bash /bash-init/run.sh ${@}
