#!/bin/bash

ping_pid=""

run_ping() {
  echo "starting build timer"
  (
    trap - ERR
    timer="0"
    while true; do
      sleep 60
      (( timer += 1 ))
      echo "building: $timer min"
    done
  ) &
  ping_pid="$!"
}

stop_ping() {
  if [[ ! -z $ping_pid ]]; then
    2>/dev/null kill -SIGTERM $ping_pid || true
    2>/dev/null wait $ping_pid || true
    ping_pid=""
  fi
}

script_dir="$( cd "$( dirname "$0" )" && pwd )"

scripts_repo="$1"
configs_repo="$2"
openwrt_version="$3"
build_name="$4"
operation="$5"

if [[ ! -z $operation ]]; then
  shift 5
else
  shift 4
fi

if [[ -z $scripts_repo || -z $configs_repo || -z $openwrt_version || -z $build_name ]]; then
  echo "usage: build.sh <scripts_repo> <configs_repo> <openwrt_version> <build_name> [operation]"
  echo "see invocation examples at .travis.yml"
  exit 2
fi

jobs_count=`nproc 2>/dev/null`
(( jobs_count *= 2 ))
[[ -z $jobs_count ]] && jobs_count="1"

echo "build config:"
echo "scripts_repo: $scripts_repo"
echo "configs_repo: $configs_repo"
echo "openwrt_version: $openwrt_version"
echo "build_name: $build_name"
echo "operation: $operation"
echo "jobs count: $jobs_count"
echo



pushd "$script_dir" 1>/dev/null
commit_hash=`git rev-parse HEAD`
popd 1>/dev/null

if [[ -z $commit_hash ]]; then
  commit_hash="unknown_git_commit"
fi

scripts_dir="$script_dir/external/scripts"
configs_dir="$script_dir/external/configs"
config_file="$configs_dir/$openwrt_version/$build_name.diffconfig"

cache_dir="$HOME/.cache/openwrt_build"
if [[ ! -z OPENWRT_BUILD_CACHE_DIR ]]; then
  cache_dir="$OPENWRT_BUILD_CACHE_DIR"
fi

echo "using cache directory at $cache_dir"

build_hash=`echo "${TRAVIS_BUILD_ID}${openwrt_version}${build_name}${commit_hash}" | sha256sum -t - | cut -f1 -d' '`
cache_stage="$cache_dir/stage_${build_hash}"
cache_status="$cache_dir/status_${build_hash}"
temp_dir=`mktemp -d -t XXXXXX`

mkdir -pv "$cache_stage"
mkdir -pv "$cache_status"

clean_cache() {
  echo "cleaning stage-cache files"
  while read file; do
    echo "trimming $file"
    rm "$file"
    touch "$file"
  done < <(find "$cache_stage" -type f)
}

on_error() {
  echo "build failed!"
  stop_ping
  clean_cache
  exit 0
}

trap on_error ERR

clean_env() {
  echo "cleaning up build env"
  . "$scripts_dir/Build/clean-env.sh.in"
  echo "env after cleanup:"
  export
  echo
}

full_init() {
  clean_cache

  #remove dir with extra stuff needed for build
  rm -rf "$script_dir/external"
  mkdir -pv "$script_dir/external"

  pushd "$script_dir" 1>/dev/null

  #init helper repos
  pushd "$script_dir/external" 1>/dev/null
  echo "installing build scripts"
  git clone --depth 1 "$scripts_repo" scripts
  echo "installing build configs"
  git clone --depth 1 "$configs_repo" configs
  popd 1>/dev/null

  #clean_env
  clean_env

  echo "running build preparation scripts:"
  while read script; do
    echo "running $script"
    "$script"
  done < <(find "$scripts_dir/Build/$openwrt_version" -type f | sort)

  echo "installing config from $config_file"
  cp "$config_file" .config
  make defconfig
  ./scripts/diffconfig.sh > test.diffconfig
  echo "ensuring diffconfig is unchanged"
  diff "test.diffconfig" "$config_file" 1>/dev/null
  rm -v "test.diffconfig"

  popd 1>/dev/null
}

create_pack() {
  local pack_tar="$operation.tar"
  local pack_z="$operation.tar.xz"
  echo "creating pack: $cache_stage/$pack_z"
  rm -f "$cache_stage/$pack_tar"
  rm -f "$cache_stage/$pack_z"
  mkdir -p "$temp_dir/$operation"
  rsync --exclude="/.git" --exclude="/build.sh" -vrlHpEogDtW --numeric-ids --delete-before --quiet "$script_dir"/ "$temp_dir/$operation"/
  pushd "$temp_dir" 1>/dev/null
  tar cf "$pack_tar" "$operation"
  xz --threads=$jobs_count -2 "$pack_tar"
  mv "$pack_z" "$cache_stage/$pack_z"
  popd 1>/dev/null
  rm -rf "$cache_stage/$operation"
  echo "creating stage-completion mark $cache_status/$operation"
  touch "$cache_status/$operation"
}

restore_pack() {
  local operation="$1"
  local pack_z="$operation.tar.xz"
  echo "checking stage-completion mark $cache_status/$operation"
  if [[ ! -f "$cache_status/$operation" ]]; then
    echo "no stage-completion mark found at $cache_status/$operation"
    echo "cannot proceed..."
    trap - ERR
    stop_ping
    clean_cache
    return 1
  fi
  echo "restoring pack: $cache_stage/$pack_z"
  pushd "$temp_dir" 1>/dev/null
  xz -c -d "$cache_stage/$pack_z" | tar xf -
  rsync --exclude="/.git" --exclude="/build.sh" -vcrlHpEogDtW --numeric-ids --delete-before --quiet "$temp_dir/$operation"/ "$script_dir"/
  popd 1>/dev/null
  echo "cleaning up"
  rm -rf "$temp_dir/$operation"
  echo "trimming $cache_stage/$pack_z"
  rm "$cache_stage/$pack_z"
  touch "$cache_stage/$pack_z"
}

# handle build stages

if [[ $operation = "prepare" ]]; then
  run_ping
  full_init
  make download -j$jobs_count
  stop_ping
  create_pack
elif [[ $operation = "tools" ]]; then
  run_ping
  restore_pack "prepare"
  clean_env
  make tools/install -j$jobs_count
  create_pack
elif [[ $operation = "toolchain_prep" ]]; then
  run_ping
  restore_pack "tools"
  clean_env
  make toolchain/gcc/initial/compile -j$jobs_count
  create_pack
elif [[ $operation = "toolchain_final" ]]; then
  run_ping
  restore_pack "toolchain_prep"
  clean_env
  make toolchain/install -j$jobs_count
  create_pack
elif [[ $operation = "firmware" ]]; then
  run_ping
  restore_pack "toolchain_final"
  clean_env
  make world -j$jobs_count
  create_pack
else
  echo "operation $operation is not supported"
  clean_cache
  exit 1
fi

stop_ping