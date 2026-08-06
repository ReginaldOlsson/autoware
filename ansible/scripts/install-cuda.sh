#!/usr/bin/env bash
# Manual CUDA install matching ansible/roles/cuda (when full ansible /
# setup-dev-env.sh is awkward, e.g. ROS 2 Jazzy on Ubuntu 24.04).
#
# Mirrors role defaults:
#   Ubuntu 24.04 -> CUDA 13.0, repo ubuntu2404
#   Ubuntu 22.04 -> CUDA 12.8, repo ubuntu2204
#   install_devel=y (toolkit + -dev packages)
#
# Drivers: skips nvidia-open when nvidia-smi already works.
# Pass --install-drivers to also install the ansible `nvidia-open` package.
#
# Usage (from repo root or anywhere):
#   bash ansible/scripts/install-cuda.sh
#   bash ansible/scripts/install-cuda.sh --install-drivers

set -euo pipefail

INSTALL_DRIVERS=false
for arg in "$@"; do
  case "$arg" in
    --install-drivers) INSTALL_DRIVERS=true ;;
    -h|--help)
      echo "Usage: $0 [--install-drivers]"
      echo
      echo "Installs CUDA toolkit packages matching ansible/roles/cuda."
      echo "  --install-drivers  Also install nvidia-open (may replace Ubuntu drivers; reboot needed)"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--install-drivers]" >&2
      exit 1
      ;;
  esac
done

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run as root; run as your user so PATH updates go to ~/.bashrc" >&2
  exit 1
fi

if ! command -v lsb_release >/dev/null 2>&1; then
  echo "lsb_release is required" >&2
  exit 1
fi

UBUNTU_VERSION="$(lsb_release -rs)"
case "${UBUNTU_VERSION}" in
  24.04)
    CUDA_VERSION=13.0
    REPO=ubuntu2404
    ;;
  22.04)
    CUDA_VERSION=12.8
    REPO=ubuntu2204
    ;;
  *)
    echo "Unsupported Ubuntu version: ${UBUNTU_VERSION} (expected 22.04 or 24.04)" >&2
    exit 1
    ;;
esac

CUDA_DASH="${CUDA_VERSION//./-}"
case "$(uname -m)" in
  x86_64) ARCH=x86_64 ;;
  aarch64) ARCH=sbsa ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

KEYRING_DEB="/tmp/cuda-keyring_${REPO}_1.1-1_all.deb"

echo "==> Host: Ubuntu ${UBUNTU_VERSION} / ${ARCH}"
echo "==> Target: CUDA ${CUDA_VERSION} (repo ${REPO})"

echo "==> [1/5] Installing NVIDIA CUDA keyring for ${REPO}/${ARCH}"
wget -q "https://developer.download.nvidia.com/compute/cuda/repos/${REPO}/${ARCH}/cuda-keyring_1.1-1_all.deb" -O "${KEYRING_DEB}"
sudo dpkg -i "${KEYRING_DEB}"

# Ansible removes /etc/apt/sources.list.d/cuda.list; also drop leftover wrong-distro lists
sudo rm -f /etc/apt/sources.list.d/cuda.list
if [[ "${REPO}" == "ubuntu2404" ]]; then
  sudo rm -f /etc/apt/sources.list.d/cuda-ubuntu2204-x86_64.list
  sudo rm -f /etc/apt/sources.list.d/cuda-ubuntu2204-sbsa.list
elif [[ "${REPO}" == "ubuntu2204" ]]; then
  sudo rm -f /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list
  sudo rm -f /etc/apt/sources.list.d/cuda-ubuntu2404-sbsa.list
fi

echo "==> [2/5] apt update"
sudo apt-get update

echo "==> [3/5] Installing CUDA ${CUDA_VERSION} devel packages (ansible install_devel=y)"
sudo apt-get install -y \
  "cuda-command-line-tools-${CUDA_DASH}" \
  "cuda-minimal-build-${CUDA_DASH}" \
  "libcusparse-dev-${CUDA_DASH}" \
  "libcublas-dev-${CUDA_DASH}" \
  "libcurand-dev-${CUDA_DASH}" \
  "cuda-nvml-dev-${CUDA_DASH}" \
  "cuda-nvrtc-dev-${CUDA_DASH}" \
  "libnpp-dev-${CUDA_DASH}" \
  "libnvjpeg-dev-${CUDA_DASH}"

# Extra package from ansible role (CUDA 12 / Ubuntu 22.04 x86_64 only)
if [[ "${ARCH}" == "x86_64" && "${UBUNTU_VERSION}" == "22.04" ]]; then
  sudo apt-get install -y "cuda-nvprof-${CUDA_DASH}"
fi

if [[ "${INSTALL_DRIVERS}" == true ]]; then
  echo "==> [4/5] Installing nvidia-open (ansible cuda_install_drivers=true)"
  echo "    WARNING: this may replace Ubuntu's nvidia-driver-*-open and requires a reboot"
  sudo apt-get install -y nvidia-open
elif nvidia-smi >/dev/null 2>&1; then
  echo "==> [4/5] Skipping nvidia-open (nvidia-smi already works)"
  echo "    Re-run with --install-drivers to install ansible's nvidia-open package"
else
  echo "==> [4/5] nvidia-smi not working; installing nvidia-open"
  sudo apt-get install -y nvidia-open
  echo "    Reboot before relying on the GPU"
fi

echo "==> [5/5] Post-install: PATH, LD_LIBRARY_PATH, Vulkan/OpenGL/OpenCL vendors"
grep -qxF 'export PATH="/usr/local/cuda/bin:$PATH"' ~/.bashrc \
  || echo 'export PATH="/usr/local/cuda/bin:$PATH"' >> ~/.bashrc
grep -qxF 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' ~/.bashrc \
  || echo 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' >> ~/.bashrc

sudo mkdir -p /etc/vulkan/icd.d /etc/glvnd/egl_vendor.d /etc/OpenCL/vendors
sudo chmod 0755 /etc/vulkan/icd.d /etc/glvnd/egl_vendor.d /etc/OpenCL/vendors

sudo wget -q \
  https://gitlab.com/nvidia/container-images/vulkan/raw/dc389b0445c788901fda1d85be96fd1cb9410164/nvidia_icd.json \
  -O /etc/vulkan/icd.d/nvidia_icd.json
sudo chmod 0644 /etc/vulkan/icd.d/nvidia_icd.json

sudo wget -q \
  https://gitlab.com/nvidia/container-images/opengl/raw/5191cf205d3e4bb1150091f9464499b076104354/glvnd/runtime/10_nvidia.json \
  -O /etc/glvnd/egl_vendor.d/10_nvidia.json
sudo chmod 0644 /etc/glvnd/egl_vendor.d/10_nvidia.json

echo "libnvidia-opencl.so.1" | sudo tee /etc/OpenCL/vendors/nvidia.icd >/dev/null
sudo chmod 0644 /etc/OpenCL/vendors/nvidia.icd

if [[ -d "/usr/local/cuda-${CUDA_VERSION}" && ! -e /usr/local/cuda ]]; then
  sudo ln -s "/usr/local/cuda-${CUDA_VERSION}" /usr/local/cuda
fi

echo
echo "Done. Verify with:"
echo "  source ~/.bashrc"
echo "  nvcc --version    # expect ${CUDA_VERSION}"
echo "  nvidia-smi"
echo
ls -ld /usr/local/cuda* 2>/dev/null || true
# Prefer the CUDA install we just configured over any older nvcc still first on PATH
export PATH="/usr/local/cuda/bin:${PATH}"
if [[ -x /usr/local/cuda/bin/nvcc ]]; then
  /usr/local/cuda/bin/nvcc --version
else
  echo "nvcc not found under /usr/local/cuda yet — check apt install output above" >&2
fi
nvidia-smi | head -5 || true
