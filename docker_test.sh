docker run --rm --name bash-init \
  -v $(pwd):/bash-init \
  -p 8000:8000 \
  bash /bash-init/run.sh ${@}
