#/bin/sh

set -e

BUILDKIT_IMAGE=${BUILDKIT_IMAGE:-moby/buildkit:v0.9.0-rootless}
RETRIES=${RETRIES:-20}
CACHE_RESET_FREQ=${CACHE_RESET_FREQ:-4}

title() {
  echo $'\e[1m'$@$'\e[0m'
}

error() {
  echo $'\e[1;31m'$@$'\e[0m'
}

success() {
  echo $'\e[1;32m'$@$'\e[0m'
}

start_registry() {
  if [ -z "$USE_LOCAL_CACHE" ]
  then
    title "Start local registry for caching"
    registry_cache=$(docker run -d registry:2)
  fi

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

delete_image() {
  if [ -f "image.tar" ]
  then
    title "Delete tar image"
    rm image.tar
  fi
}

delete_cache() {
  if [ "$cache_type" == "local" ] && [ -d "buildcache" ]
  then
    title "Delete local cache"
    rm -rf buildcache
  fi
}

cleanup() {
  if [ -z "$NO_CLEANUP" ]
  then
    delete_image
    delete_volume
    delete_cache
    stop_registry
  fi
}

build() {
  links="--link $registry_mirror:registry-mirror"
  if [ -n "$registry_cache" ]
  then
    links="$links --link $registry_cache:registry-cache"
  fi
  docker run \
    --rm \
    -ti \
    -v $volume:/home/user/.local/share/buildkit \
    -v $PWD:/tmp/work \
    -w /tmp/work \
    -e BUILDKITD_FLAGS='--oci-worker-no-process-sandbox --config ./config.toml' \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    --entrypoint buildctl-daemonless.sh \
    $links \
    $BUILDKIT_IMAGE \
    build \
    --frontend dockerfile.v0 \
    --local dockerfile=. \
    --local context=./context \
    --opt filename=Dockerfile \
    $@
}

create_cache() {
  if [ -z "$USE_LOCAL_CACHE" ]
  then
    export_cache="type=registry,mode=max,ref=registry-cache:5000/repro:buildcache"
    import_cache="type=registry,ref=registry-cache:5000/repro:buildcache"
    cache_type="registry"
  else
    export_cache="type=local,mode=max,dest=./buildcache"
    import_cache="type=local,src=./buildcache"
    cache_type="local"
  fi

  if [ -z "$SKIP_CREATE_CACHE" ]
  then
    title "Create $cache_type cache"
    build --export-cache $export_cache
  fi
}

trap cleanup EXIT

start_registry

create_volume

create_cache

if [ -z "$SKIP_TESTS" ]
then
  for i in $(seq $RETRIES)
  do
    if [ $(( $i % 4 )) -eq 1 ]
    then
      delete_volume
      create_volume
    fi

    title "Use imported $cache_type cache to output tar image (try $i/$RETRIES)"
    build --import-cache $import_cache --output type=tar,dest=./image.tar

    if !(tar tf image.tar | grep -q repro.txt)
    then
      error "Detected missing layer in tar image!"
      error "Failed after $i tries"
      exit 1
    fi
  done

  success "Succeeded $i times - looks good"
fi
