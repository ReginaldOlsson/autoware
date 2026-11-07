# Autoware workspace skills (local)

Machine-specific notes for agents working in `/home/mosal/autoware`.
Read this before installing CUDA/TensorRT, fixing builds, or launching the planning simulator.

Also available as a Cursor project skill: `.cursor/skills/autoware-workspace/SKILL.md`.

## Environment

| Item | Value |
|------|--------|
| OS | Ubuntu 24.04 |
| ROS 2 | Jazzy (`/opt/ros/jazzy`) |
| Workspace | `/home/mosal/autoware` |
| Sample map | `$HOME/autoware_map/sample-map-planning/` |
| GPU | NVIDIA GeForce RTX 4050 Laptop |
| Driver | `nvidia-driver-595-open` (working `nvidia-smi`) |
| CUDA | **13.0** (`ubuntu2404` apt repo) |
| RMW | CycloneDDS (`rmw_cyclonedds_cpp`) |
| Compiler | `CC=/usr/bin/gcc-14`, `CXX=/usr/bin/g++-14` |

`./setup-dev-env.sh` alone is awkward here: it defaults to **Humble** and uses a deprecated playbook. Prefer `--ros-distro jazzy`, or use the manual scripts under `ansible/scripts/`.

## Shell env (required)

In `~/.bashrc` (separate lines; never append CUDA PATH onto the `CXX` line):

```bash
export CC=/usr/bin/gcc-14
export CXX=/usr/bin/g++-14
export PATH="/usr/local/cuda/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
export CYCLONEDDS_URI=file:///home/mosal/.ros/cyclonedds.xml
```

**Pitfall:** Appending CUDA `PATH` to a `CXX=...g++-14` line with no trailing newline produced `CXX=/usr/bin/g++-14export`. CMake then fails with “Could not find compiler … g++-14export”. Fix by splitting lines; verify with `echo "$CXX"`.

## CUDA / TensorRT install

Match Ansible roles for 24.04 (do **not** use `ubuntu2204` CUDA repo).

```bash
# CUDA 13.0 toolkit (skips drivers if nvidia-smi works)
bash ansible/scripts/install-cuda.sh

# TensorRT 10.13.x for CUDA 13.0 (when perception TRT packages are needed)
bash ansible/scripts/install-tensorrt.sh
```

Docs: `ansible/roles/cuda/README.md`.

## Build

```bash
source /opt/ros/jazzy/setup.bash
source ~/.bashrc
cd ~/autoware
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
```

### Known build blockers / local workarounds

1. **CUDA 13 CCCL** — Host `g++` compiling `.cpp` that includes `<cuda/std/optional>` needs `${CUDA_INCLUDE_DIRS}/cccl`. Already patched in `autoware_cuda_pointcloud_preprocessor/CMakeLists.txt`.
2. **TensorRT packages** — If TRT is missing, CMake must still call `ament_package()` (early-return stubs break install). Packages: `autoware_tensorrt_common`, classifier/plugins, `bevdet_vendor`. Install TRT then rebuild.
3. **Skipped packages** (`COLCON_IGNORE` present):
   - vision_pilot LibTorch / ONNX / CARLA Zenoh demos (`deploy_libtorch`, etc.)
   - `sodasim_gstreamer` (needs GStreamer: `libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev`)
   - `rko_lio` cmake ignore may exist; enable `-DRKO_LIO_FETCH_CONTENT_DEPS=ON` in `colcon.pkg` if building it (missing `robin-map-dev`).
4. **system package** — `sudo apt install ros-jazzy-geometric-shapes` if that dependency fails.
5. **spconv** — Ansible may skip on 24.04; some TRT plugins need it separately.

## CycloneDDS (planning simulator)

Without this, many nodes die with:

`Failed to find a free participant index for domain 0`

Host config is `~/.ros/cyclonedds.xml` with `ParticipantIndex=none` (not the docker `lo`-only config). Export `CYCLONEDDS_URI` as above.

## Planning simulator

```bash
source /opt/ros/jazzy/setup.bash
source ~/autoware/install/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file:///home/mosal/.ros/cyclonedds.xml

ros2 launch autoware_launch planning_simulator.launch.xml \
  map_path:=$HOME/autoware_map/sample-map-planning
```

### Expected flow

1. Map loads (`lanelet2_map_loader`: Succeeded / Map is published).
2. Early `logging_diag_graph` STALE/ERROR and MRM emergency noise is normal until pose/route exist.
3. In RViz: **2D Pose Estimate**, then **2D Goal Pose**.
4. State: Initializing → WaitingForRoute → Planning → WaitingForEngage.
5. Engage from RViz / ADAPI when ready.

### `[pcl::fromPCLPointCloud2] No data to copy` spam

- Source: parking `costmap_generator` (`component_container_mt` / `parking_container`).
- Cause: planning sim publishes **empty** `/perception/obstacle_segmentation/pointcloud`; PCL warns on every empty `fromROSMsg`.
- Fix: skip PCL conversion when `width * height == 0` in `autoware_costmap_generator` `getTransformedPointCloud()` (local patch). Rebuild: `colcon build --packages-select autoware_costmap_generator`.

### Other benign log noise

- `setMap() for invalid version map` — sample map has null `format_version`.
- TF `map`↔`base_link` errors until pose estimate is set.
- `waiting initialization...` on simple_planning_simulator until initial pose.

## Local patch: Hybrid A* greedy single-successor openlist

Package: `autoware_freespace_planning_algorithms`  
Sources:

- `src/universe/autoware_universe/planning/autoware_freespace_planning_algorithms/src/astar_search.cpp`
- `src/universe/autoware_universe/planning/autoware_freespace_planning_algorithms/include/autoware/freespace_planning_algorithms/astar_search.hpp`

### Intent

Upstream Hybrid A* expands every valid steering successor into `openlist_` (and again for reverse when `astar.use_back` is true). Local desired behavior is a **fast greedy / beam-width-1** search:

1. Still evaluate all steering angles in `expandNodes` (forward and optional reverse).
2. Defer graph writes during the steering loop.
3. Across forward + reverse, pick the **single lowest-`total_cost` successor**.
4. Commit that node only (`status=Open`, set fields, `openlist_.push`).

This is intentionally incomplete / non-optimal for speed. No ROS toggle yet (always-on when the patch is applied).

### Implementation sketch (re-apply if missing)

Check for `ExpansionCandidate` / `commitExpansion` in the header. If absent, stock code is back.

In `search()` replace:

```cpp
expandNodes(*current_node);
if (astar_param_.use_back) expandNodes(*current_node, true);
```

with: expand forward, expand reverse if `use_back`, keep the cheaper candidate, then `commitExpansion(best)`.

`expandNodes` should return `ExpansionCandidate` (best only), not push. Cost metric = existing `total_cost` (currently `move_cost + estimateCost(...)` in stock).

Rebuild:

```bash
colcon build --packages-select autoware_freespace_planning_algorithms --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
```

Plan reference: `~/.cursor/plans/greedy_single_successor_4135851e.plan.md`

## MoveIt / OMPL Ackermann freespace backend

Packages under `src/universe/autoware_universe/planning/`:

- `ackermann_ompl_plugins` — OMPL Reeds-Shepp state space + `AckermannOmplSolver`
- `autoware_moveit_freespace_planning_algorithms` — `MoveItAckermannPlanner : AbstractPlanningAlgorithm` (`makePlan` / OccupancyGrid)
- `autoware_moveit_freespace_planner` — drop-in parking node (same topics as legacy freespace planner)
- `ackermann_moveit_config` / `ackermann_planning_msgs` — config + optional PlanPath.srv (not used by Autoware path)

Switch at launch (default remains legacy Hybrid A*):

```bash
# Prefer system OMPL once installed:
#   sudo apt install ros-jazzy-ompl
# Until then, use the extracted overlay:
export CMAKE_PREFIX_PATH=$HOME/autoware/local_ros_overlay/opt/ros/jazzy:$CMAKE_PREFIX_PATH
export LD_LIBRARY_PATH=$HOME/autoware/local_ros_overlay/opt/ros/jazzy/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH

ros2 launch autoware_launch planning_simulator.launch.xml \
  map_path:=$HOME/autoware_map/sample-map-planning \
  freespace_backend:=moveit
```

Rebuild:

```bash
colcon build --packages-select \
  ackermann_ompl_plugins \
  autoware_moveit_freespace_planning_algorithms \
  autoware_moveit_freespace_planner \
  --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
```

## FAR-LIO and vehicle-speed dependence

Open design. Do not “fix” this by publishing a permanent zero twist. The user wants a scheme that removes the vehicle-speed requirement for Boreas replay, then judges localization only after that scheme exists.

### Why Autoware asks for vehicle speed

The gyro odometer does not estimate speed. It copies wheel speed and replaces angular velocity with the IMU, rotated into `base_link`.

```
/vehicle/status/velocity_status          autoware_vehicle_msgs/VelocityReport
  -> vehicle_velocity_converter
  -> /sensing/vehicle_velocity_converter/twist_with_covariance
  -> autoware_gyro_odometer
       + /sensing/imu/imu_data
       + TF base_link -> imu frame
  -> /localization/twist_estimator/twist_with_covariance
  -> autoware_ekf_localizer          (predict step)
  -> /localization/kinematic_state   and map -> base_link
```

Launch wiring:

- `tier4_localization_launch/launch/pose_twist_estimator/gyro_odometer.launch.xml` remaps vehicle twist from `/sensing/vehicle_velocity_converter/twist_with_covariance`.
- `pose_twist_fusion_filter.launch.xml` sets `use_twist_with_covariance` true. EKF input is `/localization/twist_estimator/twist_with_covariance`. Stop filter, twist2accel, and pose-instability detector also read that twist.
- `ekf_localizer.param.yaml` has no switch to disable twist. Missing twist becomes `twist_no_update` diagnostics. Pose initialization also waits on twist to decide that the vehicle is stopped.

The EKF uses speed to predict motion between lidar poses (about 10 Hz). Yaw rate comes from the IMU via the gyro odometer. Without a linear speed, the filter keeps the last velocity, which is why a fake zero twist makes `kinematic_state` lag as soon as the car moves.

### What does not need vehicle speed

FAR-LIO’s own EKF (`tam_state_estimation_node_ekf_3d_nh`) subscribes to `/sensing/imu/imu_data` directly. It does not read `/vehicle/status/velocity_status` or the gyro odometer. Lidar odometry (`tam_cuda_gicp_ext`) waits on TF `map` -> `base_link` (`node.wait_tf: true` in `autoware_launch/config/localization/far_lio/far_lio.param.yaml`) and uses that as the registration guess. That TF is published by the Autoware EKF, which is why the stack still looks like it needs wheel speed.

### Map registration, same roles as NDT

NDT (`ndt.addTarget` + `align(scan)`) uses the static point-cloud map as the **target** and the live scan as the **source**. FAR-LIO GICP already does that: `register_frame` transforms the scan by the `map` -> `base_link` guess and solves it onto the voxel map. `pipeline.update_map: false` so the scan is not written into the map.

The map must be `/map/pointcloud_map` (loader `enable_whole_load`), served by `far_lio_map_adapter` without waiting for a pose. A local crop of `map_radius` is used once a pose exists. Do not subscribe to `/initialpose3d` with transient-local durability: `pose_initializer` publishes that topic reliable + volatile, and the EKF pose input is also reliable + volatile. A transient-local pose bridge never connects, so FAR-LIO odometry never reaches the EKF.

Boreas (`~/rosbags/boreas_bag`) has `/boreas/pointcloud`, `/boreas/imu`, `/boreas/gnss/fix`. It has no `VelocityReport`. Ground-truth linear velocity is in `~/Downloads/boreas-2020-11-26-13-58/applanix/lidar_poses.csv` (`vel_east`, `vel_north`, `vel_up`, metres per second in the local ENU frame). Angular velocity is in the IMU message and in that same CSV.

### Temporary test only

Publishing a zero `geometry_msgs/TwistWithCovarianceStamped` on `/localization/twist_estimator/twist_with_covariance` at 50 Hz, with `--use-sim-time`, unblocks initialization. It is not a speed source. Gyro-odometer errors can be ignored while that topic is fed directly, because the EKF does not read the vehicle topic itself.

### Next scheme (not implemented)

Pick one and keep FAR-LIO’s IMU path unchanged:

1. Publish `VelocityReport.longitudinal_velocity` from the ground-truth ENU velocity rotated into `base_link`, and leave the gyro odometer in place so yaw rate still comes from the IMU.
2. Bypass the gyro odometer: publish `TwistWithCovarianceStamped` in `base_link` with forward speed from that same ground truth and angular velocity from `/sensing/imu/imu_data`.
3. Stop using the Autoware EKF as the motion model for this replay. Something else must still broadcast a single `map` -> `base_link` for FAR-LIO’s `wait_tf`, and only one parent of `base_link` is allowed.

### Boreas replay context the scheme has to keep

- Sensor model `boreas_sensor_kit`. Do not use `sample_sensor_kit` (four Velodynes, Tamagawa IMU).
- `base_link` in the bag is the lidar origin, 0.13 m above the Applanix frame (x-right, y-forward, z-up). URDF: `base_link` -> `lidar` yaw −45°, `imu` and `applanix` at z −0.13 m. `sample_vehicle` is only the mesh.
- Play `ros2 bag play ~/rosbags/boreas_bag --clock --topics /boreas/pointcloud /boreas/imu /boreas/gnss/fix`. Do not play `/tf_static` (TF cycle with the URDF) or the recorded `/clock`.
- Adapter `boreas_sensor_kit_launch/script/boreas_cloud_adapter.py` publishes `/sensing/lidar/concatenated/pointcloud` as Autoware `PointXYZIRC` (16 bytes: float32 xyz, uint8 intensity, uint8 return_type=1, uint16 channel). Perception `crop_box_filter` rejects float32 `PointXYZI`.
- Map for the test is built by `gt_map_accumulator` from `lidar_poses.csv` plus raw `.bin` deskew (`PointCloud.remove_motion`). The bag `time` field is one float32 GPS stamp per cloud and cannot deskew. Pose rotation must match pyboreas `roll @ pitch @ yaw`, not a standard ZYX matrix.
- Clouds are not deskewed in the live adapter. The map is. That mismatch is still open.
- Logging-sim planning, control, perception, and steering diagnostics are expected when those modules are left on and no route exists. Localization-only launch: `perception:=false planning:=false control:=false`.

## Agent habits for this repo

- Prefer editing packages under `src/` and rebuilding with `colcon build --packages-select <pkg>`.
- Do not commit unless the user asks; many untracked artifacts (lane detection images, `.deb`, etc.) are local.
- Do not force-push or rewrite git history.
- When debugging launch: check CycloneDDS first, then whether map/pose/odometry topics exist, then planning/control readiness.
- Prefer host CycloneDDS config with `ParticipantIndex=none` over disabling RMW.
- Before changing Hybrid A* / freespace parking planner, re-read **Local patch: Hybrid A* greedy single-successor openlist** above and verify whether the patch is present in `astar_search.cpp`.
- Before changing Boreas localization twist, gyro odometer, or the Autoware EKF, re-read **FAR-LIO and vehicle-speed dependence**.

## Quick checklist (new agent)

1. Read this file and `.cursor/skills/autoware-workspace/SKILL.md`.
2. Confirm `echo $CXX` → `/usr/bin/g++-14`, `nvcc --version` → 13.x, `echo $CYCLONEDDS_URI` set.
3. Source ROS + `install/setup.bash` before `ros2` commands.
4. For CUDA/TRT gaps, use `ansible/scripts/install-cuda.sh` / `install-tensorrt.sh`, not random NVIDIA `.run` installs.
5. For simulator spam/errors, check map path, pose estimate, and known empty-cloud / participant-index issues above.
6. If working on freespace / parking A*: confirm whether greedy single-successor openlist patch is applied.
7. If working on FAR-LIO / Boreas localization, read **FAR-LIO and vehicle-speed dependence** below before changing twist, gyro odometer, or the EKF.
