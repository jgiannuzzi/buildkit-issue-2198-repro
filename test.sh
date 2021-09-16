#/bin/sh

set -e

BUILDKIT_IMAGE=${BUILDKIT_IMAGE:-moby/buildkit:v0.9.0-rootless}
RETRIES=${RETRIES:-20}
CACHE_RESET_FREQ=${CACHE_RESET_FREQ:-4}

title() {
  echo $'\e[1;33m'$@$'\e[0m'
}

start_registry() {
  title "Start local registry for caching"
  registry_cache=$(docker run -d registry:2)
  title "Start local registry for mirroring"
  registry_mirror=$(docker run -d -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io registry:2)
}

stop_registry() {
  if [ -n "$registry_cache" ]
  then
    title "Stop local registry for caching"
    docker rm -vf $registry_cache
  fi

  if [ -n "$registry_mirror" ]
  then
    title "Stop local registry for mirroring"
    docker rm -vf $registry_mirror
  fi
}

create_volume() {
  delete_volume
  title "Create buildkit cache volume"
  volume=$(docker volume create)
}

delete_volume() {
  if [ -n "$volume" ]
  then
    title "Delete buildkit cache volume"
    docker volume rm $volume
  fi
}

cleanup() {
  delete_volume
  stop_registry
}

build() {
  docker run \
    --rm \
    -ti \
    -v $volume:/home/user/.local/share/buildkit \
    -v $PWD:/tmp/work \
    -w /tmp/work \
    --link $registry_cache:registry-cache \
    --link $registry_mirror:registry-mirror \
    -e BUILDKITD_FLAGS='--oci-worker-no-process-sandbox --config ./config.toml' \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    --entrypoint buildctl-daemonless.sh \
    $BUILDKIT_IMAGE \
    build \
    --frontend dockerfile.v0 \
    --local dockerfile=. \
    --local context=./context \
    --opt filename=Dockerfile \
    $@
}

trap cleanup EXIT

start_registry

create_volume

title "Create registry cache"
build --export-cache type=registry,mode=max,ref=registry-cache:5000/repro:buildcache

for i in $(seq $RETRIES)
do
  if [ $(( $i % 4 )) -eq 1 ]
  then
    create_volume
  fi

  title "Use registry cache to output tar image (try $i/$RETRIES)"
  build --import-cache type=registry,ref=registry-cache:5000/repro:buildcache --output type=tar,dest=./image.tar

  if !(tar tf image.tar | grep -q repro.txt)
  then
    title "Failed after $i tries"
    exit 1
  fi
done

title "Succeeded $i times - looks good"
