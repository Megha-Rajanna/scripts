#!/bin/bash
# © Copyright IBM Corporation 2024.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Sysdig/0.36.1/build_sysdig.sh
# Execute build script: bash build_sysdig.sh    (provide -h for help)
set -e -o pipefail
PACKAGE_NAME="sysdig"
PACKAGE_VERSION="0.36.1"
export SOURCE_ROOT="$(pwd)"
TEST_USER="$(whoami)"
FORCE="false"
TESTS="false"

source "/etc/os-release"
DISTRO="$ID-$VERSION_ID"
LOG_FILE="$SOURCE_ROOT/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-${DISTRO}-$(date +"%F-%T").log"

trap cleanup 0 1 2 ERR
#Check if directory exists
if [ ! -d "$SOURCE_ROOT/logs/" ]; then
    mkdir -p "$SOURCE_ROOT/logs/"
fi

function prepare() {
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
            *) echo "Please provide Correct input to proceed." ;;
            esac
        done
    fi
}
function cleanup() {
    printf -- '\nCleaned up the artifacts\n'
    sudo rm -rf $SOURCE_ROOT/cmake-3.20.3  $SOURCE_ROOT/cmake-3.20.3.tar.gz  $SOURCE_ROOT/openssl-1.1.1l  $SOURCE_ROOT/openssl-1.1.1l.tar.gz
}

function configureAndInstall() {
    printf -- '\nConfiguration and Installation started \n'
    printf -- 'User responded with Yes. \n'
    printf -- 'Building dependencies\n'

    if [[ ${DISTRO} =~ rhel-7\.[8-9] ]] ; then
        printf -- 'Building openssl v1.1.1l\n'
        cd $SOURCE_ROOT
        wget https://www.openssl.org/source/openssl-1.1.1l.tar.gz --no-check-certificate
        tar -xzf openssl-1.1.1l.tar.gz
        cd openssl-1.1.1l
        ./config --prefix=/usr/local --openssldir=/usr/local
        make
        sudo make install

        sudo mkdir -p /usr/local/etc/openssl
        sudo wget https://curl.se/ca/cacert.pem --no-check-certificate -P /usr/local/etc/openssl

        LD_LIBRARY_PATH=/usr/local/lib/:/usr/local/lib64/${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
        export LD_LIBRARY_PATH
        export SSL_CERT_FILE=/usr/local/etc/openssl/cacert.pem
        printf -- 'openssl installed successfully\n'

        printf -- 'Building cmake v3.20.3\n'
        cd $SOURCE_ROOT
        wget https://github.com/Kitware/CMake/releases/download/v3.20.3/cmake-3.20.3.tar.gz --no-check-certificate
        tar -xvzf cmake-3.20.3.tar.gz
        cd cmake-3.20.3
        ./bootstrap
        make
        sudo make install
        cmake --version
        printf -- 'cmake installed successfully\n'
    fi

    printf -- '\nDownloading Sysdig source. \n'
    cd "${SOURCE_ROOT}"
    git clone https://github.com/draios/sysdig.git
    cd sysdig
    git checkout "$PACKAGE_VERSION"
    if [[ ${DISTRO} == rhel-9.* || ${DISTRO} == ubuntu-24.04 ]]; then
        sed -i 's,7.0.0+driver,7.1.0+driver,g' ./cmake/modules/driver.cmake
        sed -i 's,9f2a0f14827c0d9d1c3d1abe45b8f074dea531ebeca9859363a92f0d2475757e,ec493d549d7dc6d9a5534e91e0350aa06827f91c7119818d88c22e8a2820f416,g' ./cmake/modules/driver.cmake
    fi
    mkdir build && cd build
    printf -- '\nStarting Sysdig build. \n'
    cmake -DCREATE_TEST_TARGETS=ON -DUSE_BUNDLED_DEPS=ON -DSYSDIG_VERSION=$PACKAGE_VERSION ..
    cd $SOURCE_ROOT/sysdig/build
    sed -i 's,c-ares.haxx.se/download/,github.com/c-ares/c-ares/releases/download/cares-1_19_1/,g' ./c-ares-prefix/src/c-ares-stamp/download-c-ares.cmake
    sed -i 's,c-ares.haxx.se/download/,github.com/c-ares/c-ares/releases/download/cares-1_19_1/,g' ./falcosecurity-libs-repo/falcosecurity-libs-prefix/src/falcosecurity-libs/cmake/modules/cares.cmake
    make
    sudo make install
    printf -- '\nSysdig build completed successfully. \n'

    printf -- '\nInserting Sysdig kernel module. \n'
    sudo rmmod scap || true
    cd $SOURCE_ROOT/sysdig/build/driver
    sudo insmod scap.ko
    printf -- '\nInserted Sysdig kernel module successfully. \n'
    # Run Tests
    runTest
}
function runTest() {
    set +e
    if [[ "$TESTS" == "true" ]]; then
    # Run tests
    #Check if directory exists
        if [ -d "$SOURCE_ROOT/sysdig" ]; then
            cd $SOURCE_ROOT/sysdig/build/
            make run-unit-test-libsinsp
        fi
    fi
    set -e
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
    echo "  bash build_sysdig.sh  [-d debug] [-y install-without-confirmation] [-t install-with-tests]"
    echo
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
            printf -- "%s is detected with version %s .\n" "$PACKAGE_NAME" "$PACKAGE_VERSION" | tee -a "$LOG_FILE"
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
    printf -- '\nRun sysdig --help to see all available options to run sysdig\n'
    printf -- "\nRun sysdig: \n"
    printf -- "    sysdig --version \n\n"
    printf -- "    sudo /usr/local/bin/sysdig \n\n"
    printf -- "    sudo /usr/local/bin/csysdig \n\n"
    printf -- '\nFor more information on sysdig, please visit https://docs.sysdig.com/?lang=en \n\n'
    printf -- '**********************************************************************************************************\n'
}
logDetails
prepare

case "$DISTRO" in
"ubuntu-20.04" | "ubuntu-22.04" | "ubuntu-23.10" | "ubuntu-24.04")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"
    sudo apt-get update >/dev/null
    export DEBIAN_FRONTEND=noninteractive
    sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y  git g++ gcc linux-headers-generic cmake libelf-dev pkg-config kmod |& tee -a "$LOG_FILE"
    sudo mkdir -p /lib/modules/$(uname -r)
    version=$(ls /usr/src/ | grep generic | tail -1)
    sudo ln -s /usr/src/$version /lib/modules/$(uname -r)/build
    if [[ ${DISTRO} == ubuntu-23.10 || ${DISTRO} == ubuntu-24.04 ]]; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y  g++-11
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11
        sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11
        gcc -v
    fi

    configureAndInstall | tee -a "$LOG_FILE"
    ;;

"rhel-7.8" | "rhel-7.9")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"
    sudo mkdir -p /lib/modules/$(uname -r)
    version=$(sudo yum info kernel-devel | grep Version | awk 'NR==1{print $3}')
    release=$(sudo yum info kernel-devel | grep Release | awk 'NR==1{print $3}')
    echo $version-$release.s390x
    sudo ln -s /usr/src/kernels/$version-$release.s390x /lib/modules/$(uname -r)/build
    sudo yum install -y perl-IPC-Cmd devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-binutils rh-git227-git.s390x pkgconfig kernel-devel kmod perl |& tee -a "$LOG_FILE"
    #switch to GCC 11
    export PATH=/opt/rh/devtoolset-11/root/usr/bin:/usr/local/bin:$PATH
    #Enable git 2.27
    source /opt/rh/rh-git227/enable
    configureAndInstall | tee -a "$LOG_FILE"
    ;;

"rhel-8.8" | "rhel-8.9" | "rhel-9.2" | "rhel-9.3")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" | tee -a "$LOG_FILE"
    printf -- '\nInstalling dependencies \n' | tee -a "$LOG_FILE"
    sudo mkdir -p /lib/modules/$(uname -r)
    version=$(sudo yum info kernel-devel | grep Version | awk 'NR==1{print $3}')
    release=$(sudo yum info kernel-devel | grep Release | awk 'NR==1{print $3}')
    echo $version-$release.s390x
    # Check if the symbolic link already exists
    if [ ! -e "/lib/modules/$(uname -r)/build" ]; then
        # If the symbolic link does not exist, create it
        sudo ln -s "/usr/src/kernels/$version-$release.s390x" "/lib/modules/$(uname -r)/build"
    else
        echo "Symbolic link already exists."
    fi
    sudo yum install -y gcc gcc-c++ git cmake pkg-config elfutils-libelf-devel kernel-devel-$(uname -r) kmod perl |& tee -a "$LOG_FILE"
    configureAndInstall | tee -a "$LOG_FILE"
    ;;
*)
    printf -- "%s not supported \n" "$DISTRO" | tee -a "$LOG_FILE"
    exit 1
    ;;
esac
printSummary | tee -a "$LOG_FILE"
