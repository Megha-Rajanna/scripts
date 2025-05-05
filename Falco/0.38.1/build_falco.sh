#!/bin/bash
# © Copyright IBM Corporation 2024.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Falco/0.38.1/build_falco.sh
# Execute build script: bash build_falco.sh    (provide -h for help)

set -e -o pipefail

PACKAGE_NAME="falco"
PACKAGE_VERSION="0.38.1"
PATCH_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Falco/${PACKAGE_VERSION}/patch"

export SOURCE_ROOT="$(pwd)"

TEST_USER="$(whoami)"
FORCE="false"
TESTS="false"
LOG_FILE="$SOURCE_ROOT/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$SOURCE_ROOT/logs/" ]; then
    mkdir -p "$SOURCE_ROOT/logs/"
fi

if [ -f "/etc/os-release" ]; then
    source "/etc/os-release"
fi

DISTRO="$ID-$VERSION_ID"

function error() { echo "Error: ${*}"; exit 1; }

function prepare()
{

    if [[ "$FORCE" == "true" ]]; then
        printf -- 'Force attribute provided hence continuing with install without confirmation message\n' | tee -a "$LOG_FILE"
    else
        printf -- 'As part of the installation, dependencies would be installed/upgraded.\n'
        while true; do
            read -r -p "Do you want to continue (y/n) ? :  " yn
            case $yn in
            [Yy]*)

                break
                ;;
            [Nn]*) exit ;;
            *) echo "Please provide correct input to proceed." ;;
            esac
        done
    fi
}

function cleanup() {
    rm -rf "${SOURCE_ROOT}/cmake-3.22.5.tar.gz"
    printf -- '\nCleaned up the artifacts\n'
}

function configureAndInstall() {
    printf -- '\nConfiguration and Installation started \n'

    #Installing dependencies
    printf -- 'User responded with Yes. \n'
    printf -- 'Building dependencies\n'

    cd "${SOURCE_ROOT}"
    
    if [[ "${ID}" == "ubuntu" ]] || [[ "${DISTRO}" == "sles-12.5" ]]; then
        printf -- 'Installing Go v1.18.8\n'
        cd $SOURCE_ROOT
        wget -q https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Go/1.18.4/build_go.sh
        bash build_go.sh -y -v 1.18.8
        export GOPATH=$SOURCE_ROOT
        export PATH=$GOPATH/bin:$PATH
        export CC=$(which gcc)
        export CXX=$(which g++)
        go version
        printf -- 'Go installed successfully\n'
    fi
    
    if [[ "${DISTRO}" == "sles-12.5" ]]; then
        printf -- 'Building cmake 3.22.5\n'
        cd $SOURCE_ROOT
        wget https://github.com/Kitware/CMake/releases/download/v3.22.5/cmake-3.22.5.tar.gz
        tar -xf cmake-3.22.5.tar.gz
        cd cmake-3.22.5
        ./bootstrap -- -DCMAKE_BUILD_TYPE:STRING=Release
        make
        sudo make install
        sudo ln -sf /usr/local/bin/cmake /usr/bin/cmake
        printf -- 'cmake installed successfully\n'

        #Install clang 14
        printf -- 'Building clang 14.0.6\n'
        cd $SOURCE_ROOT
        URL=https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-14.0.6.tar.gz
        curl -sSL $URL | tar xzf - || error "Clang 14.0.6"
        cd llvm-project-llvmorg-14.0.6
        mkdir build && cd build
        cmake -DLLVM_ENABLE_PROJECTS=clang -DCMAKE_C_COMPILER="/usr/bin/gcc" -DCMAKE_CXX_COMPILER="/usr/bin/g++"  -DCMAKE_BUILD_TYPE="Release" -G "Unix Makefiles" ../llvm
        make clang
        clangbuild=${SOURCE_ROOT}/llvm-project-llvmorg-14.0.6/build
        export PATH=$clangbuild/bin:$PATH
        export LD_LIBRARY_PATH=$clangbuild/lib:$LD_LIBRARY_PATH
        cd $clangbuild/bin
        sudo ln -sf clang++ clang++-14
        export CC=${SOURCE_ROOT}/llvm-project-llvmorg-14.0.6/build/bin/clang
        export CXX=${SOURCE_ROOT}/llvm-project-llvmorg-14.0.6/build/bin/clang++-14
        cd $SOURCE_ROOT
        clang --version
    fi

    printf -- '\nDownloading Falco source. \n'
	
    cd $SOURCE_ROOT
    git clone --depth 1 -b ${PACKAGE_VERSION} https://github.com/falcosecurity/falco.git
    cd falco

    if [[ "${DISTRO}" == "sles-12.5" ]] || [[ "${DISTRO}" == "ubuntu-20.04" ]]; then 
        printf -- '\nApplying patch \n'
        curl -sSL ${PATCH_URL}/modern_bpf.patch | git apply - || error "modern_bpf patch"
    fi

    printf -- '\nStarting Falco cmake setup. \n'
    mkdir -p $SOURCE_ROOT/falco/build
    cd $SOURCE_ROOT/falco/build
    if [[ "$TESTS" == "true" ]]; then
        CMAKE_TEST_FLAG="-DBUILD_FALCO_UNIT_TESTS=On"
    else
        CMAKE_TEST_FLAG=""
    fi
    if [[ "${DISTRO}" == "sles-12.5" ]] || [[ "${DISTRO}" =~ ^rhel-8 ]] || [[ "${DISTRO}" == "ubuntu-20.04" ]]; then
        CMAKE_FLAGS="-DFALCO_ETC_DIR=/etc/falco -DUSE_BUNDLED_DEPS=On -DCMAKE_BUILD_TYPE=Release -DBUILD_DRIVER=On ${CMAKE_TEST_FLAG}"
    else # sles-15.5, sles-15.6, rhel-9, ubuntu-22.04, ubuntu-24.04
        CMAKE_FLAGS="-DFALCO_ETC_DIR=/etc/falco -DUSE_BUNDLED_DEPS=On -DCMAKE_BUILD_TYPE=Release -DBUILD_DRIVER=On -DBUILD_BPF=On -DBUILD_FALCO_MODERN_BPF=ON ${CMAKE_TEST_FLAG}"
    fi
    cmake $CMAKE_FLAGS ../
    
    printf -- '\nStarting Falco build. \n'
    cd $SOURCE_ROOT/falco/build/
    # Fix c-ares download link
    sed -i 's,c-ares.haxx.se/download/,github.com/c-ares/c-ares/releases/download/cares-1_19_1/,g' ./falcosecurity-libs-repo/falcosecurity-libs-prefix/src/falcosecurity-libs/cmake/modules/cares.cmake
    sed -i 's,c-ares.haxx.se/download/,github.com/c-ares/c-ares/releases/download/cares-1_19_1/,g' ./c-ares-prefix/src/c-ares-stamp/c-ares-urlinfo.txt
    sed -i 's,c-ares.haxx.se/download/,github.com/c-ares/c-ares/releases/download/cares-1_19_1/,g' ./c-ares-prefix/src/c-ares-stamp/download-c-ares.cmake
    make -j$(nproc)

    printf -- '\nStarting Falco install. \n'
    sudo make install
    printf -- '\nFalco build completed successfully. \n'

    printf -- '\nInserting Falco kernel module. \n'
    sudo rmmod falco || true

    cd $SOURCE_ROOT/falco/build
    sudo insmod driver/falco.ko
    printf -- '\nInserted Falco kernel module successfully. \n'

    if [[ "${DISTRO}" =~ ^rhel-9 ]] || [[ "${DISTRO}" == "ubuntu-22.04" ]] || [[ "${DISTRO}" == "ubuntu-24.04" ]] || [[ "${DISTRO}" == "sles-15.5" ]] || [[ "${DISTRO}" == "sles-15.6" ]]; then
        # To use eBPF probe driver on supported distros, copy the eBPF driver object file probe.o
        # to the default location.
        sudo mkdir /root/.falco || true
        sudo cp -f $SOURCE_ROOT/falco/build/driver/bpf/probe.o /root/.falco/falco-bpf.o
    fi

    # Run Tests
    runTest
}

function logDetails() {
    printf -- 'SYSTEM DETAILS\n' >"$LOG_FILE"
    if [ -f "/etc/os-release" ]; then
       cat "/etc/os-release" >>"$LOG_FILE"
    fi

    cat /proc/version >>"$LOG_FILE"
    printf -- "\nDetected %s \n" "$PRETTY_NAME"
    printf -- "Request details : PACKAGE NAME= %s , VERSION= %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" | tee -a "$LOG_FILE"
}

# Print the usage message
function printHelp() {
    echo
    echo "Usage: "
    echo "  bash build_falco.sh  [-d debug] [-y install-without-confirmation] [-t run-tests-after-build] "
    echo
}

function runTest() {
    set +e

    if [[ "$TESTS" == "true" ]]; then
        cd $SOURCE_ROOT/falco/build
        sudo ./unit_tests/falco_unit_tests 
    fi

    set -e
}

while getopts "h?dyt" opt; do
    case "$opt" in
    h | \?)
        printHelp
        exit 0
        ;;
    d)
        set -x
        ;;
    y)
        FORCE="true"
        ;;
    t)
        if command -v "$PACKAGE_NAME" >/dev/null; then
            printf -- "%s is detected in the system. Skipping build and running tests .\n" "$PACKAGE_NAME" | tee -a "$LOG_FILE"
            TESTS="true"
            runTest
            exit 0
        else
            TESTS="true"
        fi

        ;;
    esac
done

function printSummary() {

    printf -- '\n********************************************************************************************************\n'
    printf -- "\n* Getting Started * \n"
    printf -- "\n# Kernel module (default driver)"
    printf -- "\nRun sudo falco"
    if [[ "${DISTRO}" =~ ^rhel-9 ]] || [[ "${DISTRO}" == "ubuntu-22.04" ]] || [[ "${DISTRO}" == "ubuntu-24.04" ]] || [[ "${DISTRO}" == "sles-15.5" ]] || [[ "${DISTRO}" == "sles-15.6" ]]; then
        printf -- "\n# eBPF probe"
        printf -- "\nRun sudo FALCO_BPF_PROBE=\"\" falco"
        printf -- "\n# modern eBPF probe"
        printf -- "\nRun sudo falco --modern-bpf"
    fi
    printf -- '\nRun falco --help to see all available options to run falco.'
    printf -- '\nSee https://github.com/falcosecurity/event-generator for information on testing falco.'
    printf -- '\nFor more information on Falco please visit https://falco.org/docs/ \n\n'
    printf -- '**********************************************************************************************************\n'
}

logDetails
prepare

case "$DISTRO" in

"ubuntu-20.04")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"
  
    sudo apt-get update
    sudo apt-get install -y git cmake build-essential pkg-config autoconf wget curl patch libtool libelf-dev gcc rpm linux-headers-$(uname -r) linux-tools-$(uname -r) kmod

    cd $SOURCE_ROOT
    sudo apt-get update 
    sudo apt install -y lsb-release wget software-properties-common gnupg
    wget https://apt.llvm.org/llvm.sh
    sed -i 's,add-apt-repository "${REPO_NAME}",add-apt-repository "${REPO_NAME}" -y,g' llvm.sh
    chmod +x llvm.sh
    sudo ./llvm.sh 14
    rm ./llvm.sh

    export CC=clang-14
    export CXX=clang++-14

    sudo ln -sf /usr/bin/clang-14 /usr/bin/clang
    sudo ln -sf /usr/bin/clang++-14 /usr/bin/clang++
    
    configureAndInstall | tee -a "$LOG_FILE"
    ;;

"ubuntu-22.04")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"
  
    sudo apt-get update
    sudo apt-get install -y git cmake build-essential pkg-config autoconf wget curl patch libtool libelf-dev gcc rpm linux-headers-$(uname -r) linux-tools-$(uname -r) kmod clang llvm

    configureAndInstall | tee -a "$LOG_FILE"
    ;;

"ubuntu-24.04")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"
  
    sudo apt-get update
    sudo apt-get install -y git cmake build-essential pkg-config autoconf wget curl patch libtool libelf-dev gcc gcc-12 g++-12 rpm linux-headers-$(uname -r) linux-tools-$(uname -r) kmod clang llvm
    
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100 --slave /usr/bin/g++ g++ /usr/bin/g++-12
    export CC=$(which gcc)
    export CXX=$(which g++)

    configureAndInstall | tee -a "$LOG_FILE"
    ;;

"rhel-8.8" | "rhel-8.10")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"

    sudo yum install -y gcc gcc-c++ git make cmake autoconf automake pkg-config patch libtool elfutils-libelf-devel diffutils which createrepo libarchive wget curl rpm-build kmod kernel-devel-$(uname -r) perl-IPC-Cmd perl-bignum perl-core clang llvm bpftool

    configureAndInstall | tee -a "$LOG_FILE"
    ;;

"rhel-9.2" | "rhel-9.4")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"

    sudo yum install --allowerasing -y gcc gcc-c++ git make cmake autoconf automake pkg-config patch perl-IPC-Cmd perl-bignum perl-core perl-FindBin libtool elfutils-libelf-devel diffutils which createrepo libarchive wget curl rpm-build kmod kernel-devel-$(uname -r) go clang llvm bpftool
    go version

    configureAndInstall | tee -a "$LOG_FILE"
    ;;

"sles-12.5")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"

    SLES_KERNEL_VERSION=$(uname -r | sed 's/-default//')
    SLES_KERNEL_PKG_VERSION=$(sudo zypper se -s 'kernel-default-devel' | grep ${SLES_KERNEL_VERSION} | head -n 1 | cut -d "|" -f 4 - | tr -d '[:space:]')

	sudo zypper install -y --force-resolution gcc gcc9 gcc9-c++ git-core patch which automake autoconf libtool libopenssl-devel libcurl-devel libelf-devel "kernel-default-devel=${SLES_KERNEL_PKG_VERSION}" tar curl make python3 python36 zlib

    sudo ln -sf /usr/bin/gcc /usr/bin/s390x-linux-gnu-gcc
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 50
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-4.8 20
    sudo update-alternatives --skip-auto --config gcc
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-9 50
    export CC=$(which gcc)
    export CXX=$(which g++)

    configureAndInstall | tee -a "$LOG_FILE"
    ;;

"sles-15.5")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"

    SLES_KERNEL_VERSION=$(uname -r | sed 's/-default//')
    SLES_KERNEL_PKG_VERSION=$(sudo zypper se -s 'kernel-default-devel' | grep ${SLES_KERNEL_VERSION} | head -n 1 | cut -d "|" -f 4 - | tr -d '[:space:]')
    sudo zypper install -y gcc gcc-c++ gcc12-c++ git-core cmake patch which automake autoconf libtool libelf-devel gawk tar curl vim wget pkg-config glibc-devel-static go1.21 "kernel-default-devel=${SLES_KERNEL_PKG_VERSION}" kmod clang14 llvm14 bpftool
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 50
    export CC=$(which gcc)
    export CXX=$(which g++)
    go version
	
    configureAndInstall | tee -a "$LOG_FILE"
    ;;
    
"sles-15.6")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"

    SLES_KERNEL_VERSION=$(uname -r | sed 's/-default//')
    SLES_KERNEL_PKG_VERSION=$(sudo zypper se -s 'kernel-default-devel' | grep ${SLES_KERNEL_VERSION} | head -n 1 | cut -d "|" -f 4 - | tr -d '[:space:]')
    sudo zypper install -y gcc gcc-c++ gcc9 gcc9-c++ git-core cmake patch which automake autoconf libtool libelf-devel gawk tar curl vim wget pkg-config glibc-devel-static go1.21 "kernel-default-devel=${SLES_KERNEL_PKG_VERSION}" kmod clang17 llvm17 bpftool
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-9 50
    export CC=$(which gcc)
    export CXX=$(which g++)
    go version
	
    configureAndInstall | tee -a "$LOG_FILE"
    ;;
*)
    printf -- "%s not supported \n" "$DISTRO" | tee -a "$LOG_FILE"
    exit 1
    ;;
esac

printSummary | tee -a "$LOG_FILE"
