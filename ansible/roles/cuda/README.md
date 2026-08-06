# cuda

This role installs [CUDA Toolkit](https://developer.nvidia.com/cuda-toolkit) following [this page](https://developer.nvidia.com/cuda-12-8-0-download-archive?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=22.04&target_type=deb_network) and [this page](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#post-installation-actions).

This role also registers Vulkan, OpenGL, and OpenCL GPU vendors for future use.

## Inputs

| Name                 | Required | Description                                                      |
| -------------------- | -------- | ---------------------------------------------------------------- |
| cuda_version         | true     | The version of CUDA Toolkit.                                     |
| cuda_repo_distro     | false    | NVIDIA apt repo distro suffix (e.g. `ubuntu2204`, `ubuntu2404`). |
| cuda_install_drivers | false    | Whether to install cuda-drivers.                                 |

## Version selection

The role auto-selects CUDA version and apt repo distro based on the host's Ubuntu version:

| Ubuntu         | CUDA version | Apt repo distro | Driver package                                   |
| -------------- | ------------ | --------------- | ------------------------------------------------ |
| 22.04 (humble) | 12.8         | `ubuntu2204`    | `nvidia-open` (when `cuda_install_drivers=true`) |
| 24.04 (jazzy)  | 13.0         | `ubuntu2404`    | `nvidia-open` (when `cuda_install_drivers=true`) |

Both `cuda_version` and `cuda_repo_distro` are overridable via `-e cuda_version=…` and `-e cuda_repo_distro=…`. Override them together when installing a non-default toolkit release that NVIDIA only publishes under a different `ubuntuXXXX` repo than the host's Ubuntu version (e.g. CUDA 12.x on a 24.04 host).

## Manual Installation

Prefer this when `setup-dev-env.sh` / the full ansible playbook is awkward (for example ROS 2 Jazzy on Ubuntu 24.04) but you still need the same CUDA stack as this role.

### Recommended: install script

From the Autoware repository root:

```bash
bash ansible/scripts/install-cuda.sh
```

This installs the CUDA toolkit packages for the host Ubuntu version (13.0 on 24.04, 12.8 on 22.04), configures `PATH` / `LD_LIBRARY_PATH`, and registers Vulkan / OpenGL / OpenCL vendors.

- Skips `nvidia-open` when `nvidia-smi` already works (common when Ubuntu’s `nvidia-driver-*-open` is installed).
- Pass `--install-drivers` to also install ansible’s `nvidia-open` package (may replace Ubuntu drivers; reboot required).

After install:

```bash
source ~/.bashrc
nvcc --version
nvidia-smi
```

### Version compatibility

| Ubuntu | CUDA toolkit | Minimum NVIDIA driver |
| ------ | ------------ | --------------------- |
| 22.04  | 12.8         | 570 or newer          |
| 24.04  | 13.0         | 570 or newer          |

#### 🛠️ For Advanced Users

⚠️ **Proceed with caution**: Avoid removing essential system components.

To prevent conflicts during NVIDIA installation, we recommend completely removing old NVIDIA Drivers and CUDA by following this guide: [How can I uninstall a NVIDIA driver completely?](https://askubuntu.com/a/206289/761440).

- **Important**: If you remove the previous NVIDIA drivers, ensure you install the recommended versions listed below **before restarting your system**.

Once the drivers are installed correctly, you may safely restart your system.

### CUDA Toolkit and Driver (step-by-step)

Equivalent to `ansible/scripts/install-cuda.sh`. From: <https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#network-repo-installation-for-ubuntu>

```bash
# From the Autoware repository root — pick values matching the Version selection table above:
cuda_version=13.0          # 12.8 on Ubuntu 22.04
os=ubuntu2404              # ubuntu2204 on Ubuntu 22.04
arch_dir=$(
  case "$(uname -m)" in
    x86_64) echo x86_64 ;;
    aarch64) echo sbsa ;;
    *) echo "$(uname -m)" ;;
  esac
)

wget "https://developer.download.nvidia.com/compute/cuda/repos/${os}/${arch_dir}/cuda-keyring_1.1-1_all.deb"
sudo dpkg -i cuda-keyring_1.1-1_all.deb
# Drop leftover lists from a different Ubuntu CUDA repo if present:
sudo rm -f /etc/apt/sources.list.d/cuda.list /etc/apt/sources.list.d/cuda-ubuntu2204-*.list
sudo apt-get update
cuda_version_dashed=$(sed -e "s/[.]/-/g" <<< "${cuda_version}")
sudo apt-get -y install \
  cuda-command-line-tools-${cuda_version_dashed} \
  cuda-minimal-build-${cuda_version_dashed} \
  libcusparse-dev-${cuda_version_dashed} \
  libcublas-dev-${cuda_version_dashed} \
  libcurand-dev-${cuda_version_dashed} \
  cuda-nvml-dev-${cuda_version_dashed} \
  cuda-nvrtc-dev-${cuda_version_dashed} \
  libnpp-dev-${cuda_version_dashed} \
  libnvjpeg-dev-${cuda_version_dashed}
```

```bash
# Only if nvidia-smi is not already working — ansible installs nvidia-open:
sudo apt-get install -y nvidia-open
# Or a specific Ubuntu driver package, e.g.:
# sudo apt install nvidia-driver-595-open
```

Perform the post installation actions:

```bash
# Taken from: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#post-installation-actions
echo 'export PATH="/usr/local/cuda/bin:$PATH"' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' >> ~/.bashrc
source ~/.bashrc
```

### GPU Vendors

Register Vulkan, OpenGL, and OpenCL GPU vendors following the instructions below (also done by `ansible/scripts/install-cuda.sh`).

```bash
# Create Vulkan directory
sudo mkdir -p /etc/vulkan/icd.d
sudo chmod 0755 /etc/vulkan/icd.d

# Create OpenGL directory
sudo mkdir -p /etc/glvnd/egl_vendor.d
sudo chmod 0755 /etc/glvnd/egl_vendor.d

# Create OpenCL directory
sudo mkdir -p /etc/OpenCL/vendors
sudo chmod 0755 /etc/OpenCL/vendors

# Download and set permissions for Vulkan GPU vendors JSON
sudo wget https://gitlab.com/nvidia/container-images/vulkan/raw/dc389b0445c788901fda1d85be96fd1cb9410164/nvidia_icd.json -O /etc/vulkan/icd.d/nvidia_icd.json
sudo chmod 0644 /etc/vulkan/icd.d/nvidia_icd.json

# Download and set permissions for OpenGL GPU vendors JSON
sudo wget https://gitlab.com/nvidia/container-images/opengl/raw/5191cf205d3e4bb1150091f9464499b076104354/glvnd/runtime/10_nvidia.json -O /etc/glvnd/egl_vendor.d/10_nvidia.json
sudo chmod 0644 /etc/glvnd/egl_vendor.d/10_nvidia.json

# Register and set permissions for OpenCL GPU vendors
sudo touch /etc/OpenCL/vendors/nvidia.icd
echo "libnvidia-opencl.so.1" | sudo tee /etc/OpenCL/vendors/nvidia.icd > /dev/null
sudo chmod 0644 /etc/OpenCL/vendors/nvidia.icd
```
