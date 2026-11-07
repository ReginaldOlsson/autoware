---
name: autoware-workspace
description: >-
  Local Autoware Universe workspace on Ubuntu 24.04 + ROS 2 Jazzy + CUDA 13.
  Use when building Autoware, installing CUDA/TensorRT, fixing colcon/CMake
  errors, configuring CycloneDDS, or launching planning_simulator in
  /home/mosal/autoware.
---

# Autoware workspace (local)

Before CUDA/TRT installs, builds, or planning-simulator work, read the full notes:

**`/home/mosal/autoware/SKILLS.md`**

## Hard rules for this machine

1. **ROS:** Jazzy. Prefer `./setup-dev-env.sh --ros-distro jazzy` or manual `ansible/scripts/` — plain `setup-dev-env.sh` defaults to Humble.
2. **CUDA:** 13.0 / `ubuntu2404`. Scripts: `ansible/scripts/install-cuda.sh`, `ansible/scripts/install-tensorrt.sh`. Skip driver reinstall if `nvidia-smi` works.
3. **bashrc:** Keep `export CXX=/usr/bin/g++-14` on its **own line**. Never glue CUDA `PATH` onto it (`g++-14export` breaks CMake).
4. **CycloneDDS:** `export CYCLONEDDS_URI=file:///home/mosal/.ros/cyclonedds.xml` with `ParticipantIndex=none`. Fixes “Failed to find a free participant index for domain 0”.
5. **Planning sim:**
   ```bash
   ros2 launch autoware_launch planning_simulator.launch.xml \
     map_path:=$HOME/autoware_map/sample-map-planning
   ```
   Needs RViz **2D Pose Estimate** then **2D Goal Pose**. Early STALE diags are normal.
6. **PCL spam** `[pcl::fromPCLPointCloud2] No data to copy` → empty obstacle cloud into parking `costmap_generator`; guard empty clouds (see `SKILLS.md`).
7. **Hybrid A* local intent:** freespace planner may use greedy single-successor openlist (beam-1) instead of pushing all expansions — see `SKILLS.md` section “Local patch: Hybrid A* greedy single-successor openlist”. Files: `autoware_freespace_planning_algorithms` `astar_search.cpp` / `.hpp`.
8. **FAR-LIO / Boreas:** vehicle wheel speed is an Autoware EKF input, not a FAR-LIO input. Do not treat gyro-odometer errors as a FAR-LIO failure. Open design: remove that dependence for bag replay. See `SKILLS.md` section “FAR-LIO and vehicle-speed dependence”.

## Build reminder

```bash
source /opt/ros/jazzy/setup.bash && source ~/.bashrc
cd ~/autoware
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
# or: colcon build --packages-select <pkg>
```
