#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src
export PATH="$base/.clang/bin:$PATH"
# Helper to detect TensorFlow installation path
function detect_tensorflow() {
    if python3.11 -c "import tensorflow" >/dev/null 2>&1; then
        TENSORFLOW_INSTALL=$(python3.11 -c "import tensorflow; print(tensorflow.__path__[0])")
        export TENSORFLOW_INSTALL
    else
        # Fallback to standard path if not installed yet (for do_deps to fill)
        TENSORFLOW_INSTALL=/usr/local/lib/python3.11/dist-packages/tensorflow
        export TENSORFLOW_INSTALL
    fi
}
detect_tensorflow

# OS Detection
if [[ $(command -v dnf) ]]; then
    export OS=fedora
else
    export OS=debian
fi

# Architecture Detection
ARCH=$(uname -m)
export ARCH

set -eu

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | kernel | llvm | compress | release) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
    [[ $ARCH == "x86_64" ]] && do_kernel
}

function do_binutils() {
    local targets=("aarch64" "arm" "x86_64")

    python3.11 "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets "${targets[@]}"
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0
    if [[ $OS == "fedora" ]]; then
        dnf install -y \
            bc \
            bison \
            ccache \
            clang \
            cmake \
            compiler-rt \
            cpio \
            curl \
            flex \
            gcc-c++ \
            git \
            gh \
            libbsd-devel \
            libcap-devel \
            libedit-devel \
            libffi-devel \
            libtool \
            lld \
            llvm-devel \
            make \
            ncurses-compat-libs \
            ninja-build \
            openssl-devel \
            patch \
            patchelf \
            perl-Digest-SHA \
            python3.11 \
            python3-pip \
            python3-pyelftools \
            python3-setuptools \
            uboot-tools \
            wget \
            xz \
            zlib-devel
    else
        # Refresh mirrorlist to avoid dead mirrors
        apt update -y

        # Ensure python3.11 is available via deadsnakes PPA if needed
        if ! apt-cache show python3.11 >/dev/null 2>&1; then
            apt install -y --no-install-recommends software-properties-common
            add-apt-repository -y ppa:deadsnakes/ppa
            apt update -y
        fi

        apt install -y --no-install-recommends \
            bc \
            bison \
            ca-certificates \
            clang \
            cmake \
            curl \
            file \
            flex \
            g++ \
            gcc \
            gh \
            git \
            libbsd-dev \
            libcap-dev \
            libedit-dev \
            libelf-dev \
            libffi-dev \
            libssl-dev \
            libstdc++-12-dev \
            lld \
            make \
            ninja-build \
            patch \
            patchelf \
            python3.11 \
            python3.11-dev \
            python3.11-distutils \
            python3.11-venv \
            python3-pip \
            texinfo \
            wget \
            xz-utils \
            zlib1g-dev
    fi

    # Ensure pip is available for python3.11
    if ! python3.11 -m pip --version >/dev/null 2>&1; then
        python3.11 -m ensurepip --upgrade || {
            curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11
        }
    fi

    python3.11 -m pip install -r "$base"/requirements.txt

    # Refresh TensorFlow path after installation
    detect_tensorflow
}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux=$src/$branch

    if [[ -d $linux ]]; then
        git -C "$linux" fetch --depth=1 origin $branch
        git -C "$linux" reset --hard FETCH_HEAD
    else
        git clone \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$linux"
    fi

    cat <<EOF | env PYTHONPATH="$base"/tc_build python3.11 -
from pathlib import Path

from kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['X86']}
builder.toolchain_prefix = Path('$install')

builder.build()
EOF
}

function do_llvm() {
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)
    TomTal=$(nproc)
    TomTal=$((TomTal + 1))

    local targets=("AArch64" "ARM" "X86")

    if [[ $ARCH == "aarch64" ]]; then
        extra_args+=(--mlgo inliner_train="$base"/mlgo-models/arm64/inlining-Oz-chromium regalloc_train="$base"/mlgo-models/arm64/regalloc-evict-aosp)
    else
        extra_args+=(--mlgo inliner_train="$base"/mlgo-models/x86_64/inlining-Oz-99f0063-v1.1 regalloc_train="$base"/mlgo-models/x86_64/regalloc-evict-v1.1)
    fi

    if [[ -d ${TENSORFLOW_INSTALL:-} ]]; then
        extra_args+=(--defines "TENSORFLOW_C_LIB_PATH=$TENSORFLOW_INSTALL")
    fi

    cd "$base"/profiles
    for archive in *.tar.xz; do
        tar -xJf "$archive"
    done
    cd "$base"

    python3.11 "$base"/build-llvm.py \
        --install-folder "$install" \
        --vendor-string "$LLVM_VENDOR_STRING" \
        --targets "${targets[@]}" \
        --defines "LLVM_PARALLEL_COMPILE_JOBS=$TomTal LLVM_PARALLEL_LINK_JOBS=$TomTal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' LLVM_USE_LINKER=lld LLVM_ENABLE_LLD=ON" \
        --projects clang compiler-rt lld polly openmp \
        --no-ccache \
        --quiet-cmake \
        --llvm-folder "$base"/llvm-project \
        --lto thin \
        --pgo "$base"/profiles/r547379.profdata \
        --bolt \
        --bolt-profile "$base"/profiles/clang.fdata \
        "${extra_args[@]}"
}

function do_compress() {

    # Remove unnecessary files
    rm -fr "$install"/include
    rm -f "$install"/lib/*.a "$install"/lib/*.la

    # Copy libtensorflow if it exists
    if [[ -d ${TENSORFLOW_INSTALL:-} ]]; then
        find "$TENSORFLOW_INSTALL" -maxdepth 2 -name "libtensorflow.so*" -exec cp -P {} "$install"/lib/ \;
    fi

    # Strip remaining binaries
    # Avoid strip failing on non-ELFs
    find "$install" -type f -exec file {} \; | grep 'not stripped' | cut -d: -f1 | while read -r f; do
        strip -s "$f" || true
    done

    # Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
    find "$install" -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | cut -d: -f1 | while read -r bin; do
        echo "$bin"
        patchelf --set-rpath "$install/lib" "$bin"
    done

    # Get git commit hash
    git_hash=$(git -C "$base"/llvm-project rev-parse --short HEAD)
    clang_version=$("$base"/install/bin/clang --version | head -n 1 | awk '{print $4}')
    # Detect distro codename (e.g., bookworm, jammy, fedora40)
    if [[ -f /etc/os-release ]]; then
        distro_name=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '\"')
        # If VERSION_CODENAME is empty (common on Ubuntu/Fedora), try ID
        [[ -z $distro_name ]] && distro_name=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '\"')
        # For Fedora, append VERSION_ID for clarity
        if [[ $distro_name == "fedora" ]]; then
            version_id=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '\"')
            distro_name="${distro_name}${version_id}"
        fi
    fi

    # Default to "linux" if detection failed
    distro_name=${distro_name:-linux}
    file_name="$LLVM_VENDOR_STRING"-clang_"$clang_version"-"$distro_name"-"$ARCH"-"$git_hash".tar.xz

    # Compress the install folder to save space
    mkdir -p "$base"/dist
    cd "$install"
    tar -cJf "$base"/dist/"$file_name" -- *
    curl -X POST -F "file=@$base/dist/$file_name" https://temp.wulan17.dev/api/v1/upload
}

function do_release() {
    # Upload to GitHub Releases using GitHub CLI
    # Find tarball files
    file_name=$(find "$base"/dist/ -maxdepth 1 -name "${LLVM_VENDOR_STRING}-clang_*.tar.xz" -print -quit)

    if [[ -z $file_name ]]; then
        echo "No file found to upload."
        exit 1
    fi

    clang_version=$("$base"/install/bin/clang --version | head -n 1 | awk '{print $4}')
    git_hash=$(git -C "$base"/llvm-project rev-parse --short HEAD)

    TAG="$clang_version-$git_hash"
    ASSET="$file_name"
    REPO="$GITHUB_REPOSITORY"
    TITLE="$LLVM_VENDOR_STRING Clang $clang_version ($git_hash)"
    NOTES="$LLVM_VENDOR_STRING Clang $clang_version ($git_hash)"

    # Check if release exists
    if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
        echo "Release $TAG exists, uploading asset..."
        gh release upload "$TAG" "$ASSET" --repo "$REPO" --clobber
    else
        echo "Release $TAG does not exist, creating release and uploading asset..."
        gh release create "$TAG" "$ASSET" \
            --title "$TITLE" \
            --notes "$NOTES" \
            --target "$GITHUB_REF_NAME" \
            --repo "$REPO"
    fi
    echo "Released successfully."
}

parse_parameters "$@"
do_"${action:=all}"
