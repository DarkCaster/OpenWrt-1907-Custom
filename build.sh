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
echo

#chdir
cd "$script_dir"

#remove dir with extra stuff needed for build
rm -rfv "external"
mkdir -pv "external"

#init helper repos
pushd "external" 1>/dev/null
echo "installing build scripts"
git clone --depth 1 "$scripts_repo" scripts
echo
echo "installing build configs"
git clone --depth 1 "$configs_repo" configs
echo
popd 1>/dev/null

echo "env before cleanup:"
export
echo

echo "cleaning up build env"
. "external/scripts/Build/clean-env.sh.in"
echo

echo "env after cleanup:"
export
echo

echo "running build preparation scripts:"
while read script; do
  echo "running $script"
  "$script"
done < <(find "external/scripts/Build/$openwrt_version" -type f | sort)

config_file="external/configs/$openwrt_version/$build_name.diffconfig"
echo "installing config from $config_file"
cp "$config_file" .config
make defconfig
./scripts/diffconfig.sh > test.diffconfig
echo "ensuring diffconfig is unchanged"
diff "test.diffconfig" "$config_file" 1>/dev/null
rm -v "test.diffconfig"

echo "building openwrt (`nproc` jobs)"
make world -j$(nproc)

exit 1
