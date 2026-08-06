#!/usr/bin/env bash
# Install TensorRT matching ansible/roles/tensorrt for Ubuntu 24.04 / CUDA 13.0.
# Runtime + devel packages (install_devel=y).
#
# Usage:
#   bash ansible/scripts/install-tensorrt.sh
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run as root; run as your user (script uses sudo)." >&2
  exit 1
fi

UBUNTU_VERSION="$(lsb_release -rs)"
case "${UBUNTU_VERSION}" in
  24.04) TENSORRT_VERSION='10.13.3.9-1+cuda13.0' ;;
  22.04)
    if [[ "$(uname -m)" == "aarch64" ]]; then
      TENSORRT_VERSION='10.3.0.26-1+cuda12.5'
    else
      TENSORRT_VERSION='10.8.0.43-1+cuda12.8'
    fi
    ;;
  *)
    echo "Unsupported Ubuntu version: ${UBUNTU_VERSION}" >&2
    exit 1
    ;;
esac

echo "==> Installing TensorRT ${TENSORRT_VERSION}"
sudo apt-get update
sudo apt-get install -y \
  "libnvinfer10=${TENSORRT_VERSION}" \
  "libnvinfer-plugin10=${TENSORRT_VERSION}" \
  "libnvonnxparsers10=${TENSORRT_VERSION}" \
  "libnvinfer-dev=${TENSORRT_VERSION}" \
  "libnvinfer-plugin-dev=${TENSORRT_VERSION}" \
  "libnvinfer-headers-dev=${TENSORRT_VERSION}" \
  "libnvinfer-headers-plugin-dev=${TENSORRT_VERSION}" \
  "libnvonnxparsers-dev=${TENSORRT_VERSION}"

# Hold versions (matches ansible role)
sudo apt-mark hold \
  libnvinfer10 libnvinfer-plugin10 libnvonnxparsers10 \
  libnvinfer-dev libnvinfer-plugin-dev \
  libnvinfer-headers-dev libnvinfer-headers-plugin-dev \
  libnvonnxparsers-dev

echo
echo "Done. Verify:"
echo "  dpkg -l 'libnvinfer*' | grep ^ii"
echo "  ls /usr/include/x86_64-linux-gnu/NvInfer.h 2>/dev/null || ls /usr/include/NvInfer.h"
echo
echo "Then rebuild TensorRT packages:"
echo "  cd ~/autoware && source /opt/ros/jazzy/setup.bash"
echo "  colcon build --packages-up-to autoware_tensorrt_common autoware_tensorrt_classifier autoware_tensorrt_plugins bevdet_vendor --cmake-args -DCMAKE_BUILD_TYPE=Release"
