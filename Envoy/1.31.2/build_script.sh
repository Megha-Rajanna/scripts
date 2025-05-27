#!/bin/bash -ex
# ----------------------------------------------------------------------------
#
# Package       : envoy
# Version       : v1.34.0
# Source repo   : https://github.com/envoyproxy/envoy/
# Tested on     : UBI 9.3
# Language      : C++
# Travis-Check  : False
# Script License: Apache License, Version 2 or later
# Maintainer    : Megha Rajanna <megha.r3@ibm.com>
#
# Disclaimer: This script has been tested in root mode on given
# ==========  platform using the mentioned version of the package.
#             It may not work as expected with newer versions of the
#             package and/or distribution. In such case, please
#             contact "Maintainer" of this script.
#
# ----------------------------------------------------------------------------

PACKAGE_NAME=envoy
PACKAGE_ORG=envoyproxy
SCRIPT_PACKAGE_VERSION=v1.34.0
PACKAGE_VERSION=${1:-${SCRIPT_PACKAGE_VERSION}}
PACKAGE_URL=https://github.com/${PACKAGE_ORG}/${PACKAGE_NAME}
SCRIPT_PACKAGE_VERSION_WO_LEADING_V="${SCRIPT_PACKAGE_VERSION:1}"
PATCH_URL="https://raw.githubusercontent.com/Megha-Rajanna/scripts/refs/heads/master/Envoy/1.31.2/patch"

#Install centos and epel repos
yum config-manager --add-repo https://mirror.stream.centos.org/9-stream/CRB/s390x/os
yum config-manager --add-repo https://mirror.stream.centos.org/9-stream/AppStream//s390x/os
yum config-manager --add-repo https://mirror.stream.centos.org/9-stream/BaseOS/s390x/os
rpm --import https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

#Install dependencies
yum install -y \
    cmake \
    libatomic \
    libstdc++-devel \
    libstdc++-static \
    libtool \
    lld \
    patch \
    clang14 \
    llvm14-devel \
    python3-pip \
    openssl-devel \
    libffi-devel \
    unzip \
    wget \
    zip \
    java-21-openjdk-devel \
    git \
    gcc-c++ \
    xz \
    file \
    binutils \
    procps \
    diffutils \
    ninja-build \
    aspell \
    aspell-en \
    sudo

#Set environment variables
export JAVA_HOME=$(compgen -G '/usr/lib/jvm/java-21-openjdk-*')
export JRE_HOME=${JAVA_HOME}/jre
export PATH=${JAVA_HOME}/bin:$PATH
scriptdir=$(dirname $(realpath $0))
wdir=$(pwd)
export ENVOY_BIN=$wdir/envoy/envoy-static
export ENVOY_ZIP=$wdir/envoy/envoy-static_${PACKAGE_VERSION}_UBI9.3.zip
LLVM_HOME_DIR="/usr"

#Download Envoy source code
cd $wdir
git clone ${PACKAGE_URL}
cd ${PACKAGE_NAME} && git checkout ${PACKAGE_VERSION}
# Apply patches to allow envoy to build
curl -sSL $PATCH_URL/envoy-build.patch | git apply --allow-empty -
  
# Apply patches for failing tests
#curl -sSL $PATCH_URL/envoy-test.patch | git apply -
#curl -sSL https://github.com/envoyproxy/envoy/commit/f6a84d8c66c1346063c32d046b56e52b28b4da9a.patch | git apply -

# Move patch files to envoy/bazel which will be applied to external packages while building envoy
curl -sSL $PATCH_URL/boringssl-s390x.patch > $wdir/envoy/bazel/boringssl-s390x.patch
curl -sSL $PATCH_URL/proxy_wasm_cpp_host-s390x.patch > $wdir/envoy/bazel/proxy_wasm_cpp_host-s390x.patch
curl -sSL $PATCH_URL/grpc-s390x.patch > $wdir/envoy/bazel/grpc-s390x.patch
curl -sSL $PATCH_URL/rules_buf-s390x.patch > $wdir/envoy/api/bazel/rules_buf-s390x.patch
curl -sSL $PATCH_URL/rules_foreign_cc-s390x.patch > $wdir/envoy/bazel/rules_foreign_cc-s390x.patch
curl -sSL https://github.com/iii-i/moonjit/commit/db9c993d2ffcf09b3995b8949bb8f5026e610857.patch > $wdir/envoy/bazel/foreign_cc/luajit-s390x.patch
curl -sSL https://github.com/iii-i/moonjit/commit/e0728b5f0616088db6f7856b5eaba91625e23577.patch >> $wdir/envoy/bazel/foreign_cc/luajit-s390x.patch
curl -sSL $PATCH_URL/luajit-as.patch > $wdir/envoy/bazel/foreign_cc/luajit-as.patch
curl -sSL $PATCH_URL/quiche-s390x.patch > $wdir/envoy/bazel/quiche-s390x.patch
BAZEL_VERSION=$(cat .bazelversion)

# Build and setup bazel
cd $wdir
if [ -z "$(ls -A $wdir/bazel)" ]; then
	mkdir bazel
	cd bazel
	wget https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/bazel-${BAZEL_VERSION}-dist.zip
	unzip bazel-${BAZEL_VERSION}-dist.zip
	rm -rf bazel-${BAZEL_VERSION}-dist.zip
	env EXTRA_BAZEL_ARGS="--tool_java_runtime_version=local_jdk" bash ./compile.sh
fi
export PATH=$PATH:$wdir/bazel/output

#Install rust and cross
curl https://sh.rustup.rs -sSf | sh -s -- -y && source ~/.cargo/env
cargo install cross --version 0.2.1

#Build cargo-bazel native binary
cd $wdir
if [ -z "$(ls -A $wdir/rules_rust)" ]; then
	git clone https://github.com/bazelbuild/rules_rust
	cd rules_rust
	git checkout 0.56.0
	cd crate_universe
	cross build --release --locked --bin cargo-bazel --target=s390x-unknown-linux-gnu
	echo "cargo-bazel build successful!"
fi
export CARGO_BAZEL_GENERATOR_URL=file://$wdir/rules_rust/crate_universe/target/powerpc64le-unknown-linux-gnu/release/cargo-bazel
export CARGO_BAZEL_REPIN=true

#Build Envoy
cd $wdir/${PACKAGE_NAME}
bazel/setup_clang.sh "$LLVM_HOME_DIR"
ret=0
bazel build -c opt --config=libc++ envoy --config=clang --define=wasm=disabled --cxxopt=-fpermissive || ret=$?
if [ "$ret" -ne 0 ]
then
	echo "FAIL: Build failed."
	exit 1
fi

#Prepare binary for distribution
cp $wdir/envoy/bazel-bin/source/exe/envoy-static $ENVOY_BIN
chmod -R 755 $wdir/envoy
strip -s $ENVOY_BIN
zip $ENVOY_ZIP envoy-static

# Smoke test
$ENVOY_BIN --version || ret=$?
if [ "$ret" -ne 0 ]
then
	echo "FAIL: Smoke test failed."
	exit 2
fi

#Run tests (take several hours to execute, hence disabling by default)
#Some tests might fail because of issues with the tests themselves rather than envoy
sysctl -w net.mptcp.enabled=1
#bazel test --config=clang --config=libc++ --test_timeout=1000 --cxxopt=-fpermissive --define=wasm=disabled //test/...

#Conclude
echo "Build successful!"
echo "Envoy binary available at [$ENVOY_BIN]"
echo "Redistributable zip available at [$ENVOY_ZIP]"
