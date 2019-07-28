#!/bin/bash

scripts_repo="$1"
configs_repo="$2"
openwrt_version="$3"
build_name="$4"
operation="$5"
build_id="$6"
event_type="$7"

#hardcoded branch-specific parameters
ext_repo="https://github.com/openwrt/openwrt.git"
ext_branch="openwrt-19.07"
int_branch="custom"

set -eE

ping_pid=""

run_ping() {
  echo "starting build timer"
  (
    set +eE
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

if [[ -z $scripts_repo || -z $configs_repo || -z $openwrt_version || -z $build_name ]]; then
  echo "usage: build.sh <scripts_repo> <configs_repo> <openwrt_version> <build_name> [operation]"
  echo "see invocation examples at .travis.yml"
  exit 2
fi

jobs_count=`nproc 2>/dev/null`
### (( jobs_count *= 2 ))
[[ -z $jobs_count ]] && jobs_count="1"

echo "build config:"
echo "scripts_repo: $scripts_repo"
echo "configs_repo: $configs_repo"
echo "openwrt_version: $openwrt_version"
echo "build_name: $build_name"
echo "operation: $operation"
echo "jobs count: $jobs_count"
echo "build_id: $build_id"
echo "event_type: $event_type"
echo

pushd "$script_dir" 1>/dev/null
commit_hash=`2>/dev/null git rev-parse HEAD || true`
commit_hash_short=`2>/dev/null git log -1 --pretty=format:%h || true`
popd 1>/dev/null

if [[ -z $commit_hash || -z $commit_hash_short ]]; then
  echo "failed to detect git commit hash"
  commit_hash="unknown_git_commit"
  commit_hash_short="unknown"
fi

scripts_dir="$script_dir/external/scripts"
configs_dir="$script_dir/external/configs"
config_file="$configs_dir/$openwrt_version/$build_name.diffconfig"

cache_dir="$HOME/.cache/openwrt_build"
if [[ ! -z OPENWRT_BUILD_CACHE_DIR ]]; then
  cache_dir="$OPENWRT_BUILD_CACHE_DIR"
fi

echo "using cache directory at $cache_dir"

build_hash=`echo "${build_id}${openwrt_version}${build_name}${commit_hash}${event_type}" | sha256sum -t - | cut -f1 -d' '`

cache_stage="$cache_dir/stage_${build_hash}"
cache_status="$cache_dir/status_${build_hash}"

mkdir -pv "$cache_stage"
mkdir -pv "$cache_status"

on_error() {
  echo "build failed! (line $1)"
  trap - ERR
  stop_ping
  exit 1
}

trap 'on_error $LINENO' ERR

clean_env() {
  echo "cleaning up build env"
  . "$scripts_dir/Build/clean-env.sh.in"
  echo "env after cleanup:"
  export
  echo
}

clean_cache() {
  echo "cleaning up cache"
  rm -rfv "$cache_dir"/*
  touch "$cache_dir/clear"
}

full_init() {
  echo "cleaning-up and resetting git repo"
  git clean -dfx --force
  git checkout "$int_branch"
  git clean -dfx --force
  git reset --hard

  if [[ $event_type != "cron" ]]; then
    echo "merging latest changes from $ext_repo repo, $ext_branch branch"
    git config --local user.name "Anonymous"
    git config --local user.email "anon@somewhere.com"
    git pull --no-edit --commit "$ext_repo" "$ext_branch"
  fi

  git repack -a -d

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
  local pack_z="$operation.tar.gz"
  local src_parent=`dirname "$script_dir"`
  local src_name=`basename "$script_dir"`
  echo "creating pack: $cache_stage/$pack_z"
  rm -f "$cache_stage/$pack_z"
  echo "creating archive"
  pushd "$src_parent" 1>/dev/null
  tar cf - --exclude="$src_name/build.sh" --exclude="$src_name/.travis.yml" "$src_name" | pigz -3 - > "$cache_stage/$pack_z"
  #tar cf - --exclude="$src_name/.git" --exclude="$src_name/build.sh" --exclude="$src_name/.travis.yml" "$src_name" | lrzip -g -w 10 -L 1 -q - > "$cache_stage/$pack_z"
  #tar cf "$cache_stage/$pack_z" --exclude="$src_name/.git" --exclude="$src_name/build.sh" --exclude="$src_name/.travis.yml" "$src_name"
  popd 1>/dev/null
  echo "creating stage-completion mark $cache_status/$operation"
  touch "$cache_status/$operation"
}

restore_pack() {
  local operation="$1"
  local pack_z="$operation.tar.gz"
  local src_parent=`dirname "$script_dir"`
  echo "checking stage-completion mark $cache_status/$operation"
  if [[ ! -f "$cache_status/$operation" ]]; then
    echo "no stage-completion mark found at $cache_status/$operation"
    echo "cannot proceed..."
    trap - ERR
    stop_ping
    return 1
  fi
  echo "cleaning up source directory"
  pushd "$script_dir" 1>/dev/null
  for target in * .*
  do
    [[ $target = "." || $target = ".." || $target = "build.sh" || $target = ".travis.yml" ]] && continue || true
    echo "removing $target"
    rm -rf "$target"
  done
  popd 1>/dev/null
  echo "extracting pack: $cache_stage/$pack_z"
  pushd "$src_parent" 1>/dev/null
  pigz -c -d "$cache_stage/$pack_z" | tar xf -
  #lrzip -q -d "$cache_stage/$pack_z" -o - | tar xf -
  #tar xf "$cache_stage/$pack_z"
  popd 1>/dev/null
  echo "trimming $cache_stage/$pack_z"
  rm "$cache_stage/$pack_z"
  touch "$cache_stage/$pack_z"
}

# handle build stages

if [[ $operation = "cleanup" ]]; then
  clean_cache
elif [[ $operation = "prepare" ]]; then
  run_ping
  full_init
  make download -j$jobs_count
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
  make toolchain/compile -j$jobs_count
  create_pack
elif [[ $operation = "packages" ]]; then
  run_ping
  restore_pack "toolchain_final"
  clean_env
  make target/compile -j$jobs_count
  make diffconfig
  make package/cleanup
  make package/compile -j$jobs_count
  create_pack
elif [[ $operation = "firmware" ]]; then
  run_ping
  restore_pack "packages"
  clean_env
  make world -j1
  clean_cache
  rm -rf "bin/targets/"*/*/"packages"
  date=`date +"%Y-%m-%d"`
  result="${build_name}-${date}-${commit_hash_short}"
  echo "creating firmware archive: $script_dir/$result.tar.xz"
  tgt_count=`ls -1 "bin/targets"/* | wc -l`
  if [[ $tgt_count = "1" ]]; then
    pushd "bin/targets"/* 1>/dev/null
    mv * "$result"
  else
    pushd "bin" 1>/dev/null
    mv "targets" "$result"
  fi
  tar cf - "$result" | xz -9 - > "$script_dir/$result.tar.xz"
  popd 1>/dev/null
else
  echo "operation $operation is not supported"
  exit 1
fi

stop_ping

exit 0
