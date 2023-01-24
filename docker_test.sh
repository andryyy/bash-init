docker run --rm --name bash-init \
  -v $(pwd):/bash-init \
  bash /bash-init/run.sh stress_ng
