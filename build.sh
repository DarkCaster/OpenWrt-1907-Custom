#!/bin/bash

set -e

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

echo "build config:"
echo "scripts_repo: $scripts_repo"
echo "configs_repo: $configs_repo"
echo "openwrt_version: $openwrt_version"
echo "build_name: $build_name"
echo "operation: $operation"
echo

jobs_count=`nproc`
(( jobs_count *= 2 ))

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

cache_dl="$cache_dir/downloads_$openwrt_version_$build_name_$commit_hash"
cache_stage="$cache_dir/stage_$openwrt_version_$build_name_$commit_hash"
cache_status="$cache_dir/status_$openwrt_version_$build_name_$commit_hash"

mkdir -pv "$cache_dl"
mkdir -pv "$cache_stage"
mkdir -pv "$cache_status"

clean_env() {
  echo "performing env cleanup"
  echo "env before cleanup:"
  export
  echo
  echo "cleaning up build env"
  . "$scripts_dir/Build/clean-env.sh.in"
  echo
  echo "env after cleanup:"
  export
  echo
}

clean_cache() {
  #clean cache
  rm -rf "$cache_dl"/*
  rm -rf "$cache_stage"/*
  rm -rf "$cache_status"/*
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

mark_stage_completion() {
  echo "creating stage-completion mark $cache_status/$operation"
  touch "$cache_status/$operation"
}

create_pack() {
  local pack_tar="$operation.tar"
  local pack_z="$operation.tar.xz"
  echo "creating pack: $cache_stage/$pack_z"
  rm -rf "$cache_stage/$operation"
  rm -f "$cache_stage/$pack_tar"
  rm -f "$cache_stage/$pack_z"
  mkdir "$cache_stage/$operation"
  rsync --exclude="/.git" --exclude="/build.sh" -vcrlHpEogDtW --numeric-ids --delete-before --quiet "$script_dir"/ "$cache_stage/$operation"/
  pushd "$cache_stage" 1>/dev/null
  tar cvf "$pack_tar" "$operation"
  xz -3e "$pack_tar"
  popd 1>/dev/null
  rm -rf "$cache_stage/$operation"
  echo "current stage dir contents: $cache_stage"
  ls -la "$cache_stage"
}

restore_pack() {
  local operation="$1"
  local pack_z="$operation.tar.xz"
  echo "current stage dir contents: $cache_stage"
  ls -la "$cache_stage"
  echo "restoring pack: $cache_stage/$pack_z"
  rm -rf "$cache_stage/$operation"
  pushd "$cache_stage" 1>/dev/null
  xz -c -d "$cache_stage/$pack_z" | tar xvf -
  rsync --exclude="/.git" --exclude="/build.sh" -vcrlHpEogDtW --numeric-ids --delete-before --quiet "$cache_stage/$operation"/ "$script_dir"/
  popd 1>/dev/null
  echo "cleaning up"
  rm -rf "$cache_stage/$operation"
  rm -f "$cache_stage/$pack_z"
}

if [[ $operation = "init" ]]; then
  full_init
  create_pack
  mark_stage_completion
elif [[ $operation = "download" ]]; then
  restore_pack "init"
  clean_env
  make download -j$jobs_count V=s
  create_pack
  mark_stage_completion
else
  echo "operation $operation is not supported"
  clean_cache
  exit 1
fi









#echo "building openwrt ($jobs_count jobs)"
#make world -j$jobs_count V=s
