#!/bin/bash

set -e

script_dir="$( cd "$( dirname "$0" )" && pwd )"

scripts_repo="$1"
configs_repo="$2"
openwrt_version="$3"
build_name="$4"

if [[ -z $scripts_repo || -z $configs_repo || -z $openwrt_version || -z $build_name ]]; then
  echo "usage: build.sh <scripts_repo> <configs_repo> <openwrt_version> <build_name>"
  echo "see invocation examples at .travis.yml"
  exit 2
fi

echo "build config:"
echo "scripts_repo: $scripts_repo"
echo "configs_repo: $configs_repo"
echo "openwrt_version: $openwrt_version"
echo "build_name: $build_name"

#chdir
cd "$script_dir"

#cleanup
rm -rfv "external"
mkdir -pv "external"

#init helper repos
pushd "external"
git clone $scripts_repo scripts
git clone $scripts_repo configs
popd

exit 1
