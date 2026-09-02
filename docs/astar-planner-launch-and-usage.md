# Hybrid A* in Autoware: launch, params, construction, and usage

This note maps Hybrid A* (`AstarSearch`) from the two Behavior Path Planner (BPP) wrappers up through `autoware.launch.xml`, including YAML → C++ param wiring and the runtime conditions under which the modules actually run.

Primary sources:

- `planning/behavior_path_planner/autoware_behavior_path_goal_planner_module/src/pull_over_planner/freespace_pull_over.cpp`
- `planning/behavior_path_planner/autoware_behavior_path_start_planner_module/src/freespace_pull_out.cpp`
- `launcher/autoware_launch/autoware_launch/launch/autoware.launch.xml`

A* is **not** a standalone node in those two files. It is a library class constructed inside **goal planner** (pull-over) and **start planner** (pull-out). A third, separate node — the parking-scenario `freespace_planner` — constructs the same class with a different YAML and a different constructor.

---

## 1. Two BPP wrappers, one algorithm library

| Role | File | Algorithm object |
|---|---|---|
| Pull-over (park in) | `freespace_pull_over.cpp` | `std::unique_ptr<AstarSearch>` when `freespace_parking_algorithm == "astar"` |
| Pull-out (leave parking) | `freespace_pull_out.cpp` | `std::unique_ptr<AstarSearch>` when `freespace_planner_algorithm == "astar"` |
| Shared Hybrid A* | `autoware_freespace_planning_algorithms` | `AstarSearch` : `AbstractPlanningAlgorithm` |

Structs live in the algorithm package, **not** in the two wrappers:

- `PlannerCommonParam` — `include/autoware/freespace_planning_algorithms/abstract_algorithm.hpp`
- `AstarParam` — `include/autoware/freespace_planning_algorithms/astar_search.hpp`

The wrappers store those structs on `GoalPlannerParameters` / `StartPlannerParameters` and pass them into `AstarSearch(...)`.

---

## 2. Launch chain from `autoware.launch.xml`

```
autoware.launch.xml
  └─ launch_planning=true
       └─ tier4_planning_component.launch.xml
            ├─ preset: config/planning/preset/$(planning_module_preset)_preset.yaml
            │    default → default_preset.yaml
            │    launch_start_planner_module: true
            │    launch_goal_planner_module: true
            │    launch_parking_module: true
            │
            └─ tier4_planning_launch/.../planning.launch.xml
                 └─ scenario_planning.launch.xml   (only if planning_setting == rule_based)
                      ├─ lane_driving.launch.xml
                      │    └─ behavior_planning.launch.xml
                      │         └─ composable node BehaviorPathPlannerNode
                      │              plugin: autoware::behavior_path_planner::BehaviorPathPlannerNode
                      │              YAML: goal_planner.param.yaml + start_planner.param.yaml
                      │              costmap remap: /planning/scenario_planning/parking/costmap_generator/occupancy_grid
                      │
                      └─ parking.launch.xml   (separate A* node, not the two BPP files)
                           └─ FreespacePlannerNode + CostmapGenerator
                                YAML: parking/freespace_planner/freespace_planner.param.yaml
```

**Plugin enable switch** is in `behavior_planning.launch.xml`. If `launch_start_planner_module` / `launch_goal_planner_module` are true, it appends:

- `autoware::behavior_path_planner::StartPlannerModuleManager`
- `autoware::behavior_path_planner::GoalPlannerModuleManager`

to `behavior_path_planner_launch_modules`, then passes that list as the node parameter `launch_modules`.

`BehaviorPathPlannerNode` then does:

```cpp
for (const auto & name : declare_parameter<std::vector<std::string>>("launch_modules")) {
  planner_manager_->launchScenePlugin(*this, name);
}
```

`PlannerManager::launchScenePlugin` uses pluginlib (`plugins.xml` in each module package), then `plugin->init(&node)`.

If `planning_setting` is `diffusion_planner`, this whole BPP/A* path is skipped.

Slot order (`scene_module_manager.param.yaml`): `start_planner` in slot1, `goal_planner` in slot3. RTC is off for both (`enable_rtc: false`) so they auto-approve once requested.

---

## 3. Two A* stacks; only one drives the published trajectory

| Stack | Node | When the selector uses it |
|---|---|---|
| Lane driving (the two BPP files) | `behavior_path_planner` | `current_scenario == LANEDRIVING` |
| Parking lot | `freespace_planner` (legacy Hybrid A*) | `current_scenario == PARKING` |

BPP **returns immediately** unless the scenario is lane driving:

```cpp
// behavior_path_planner_node.cpp
if (current_scenario_->current_scenario != Scenario::LANEDRIVING) {
  return;
}
```

`scenario_selector` picks **PARKING** when ego is inside a map `parking_lot` polygon and the goal is **not** in a lane (stopped + autonomous for the live switch). Then BPP start/goal A* do not run; the parking node does.

---

## 4. Config files that feed the two BPP files

Runtime YAML is **not** the copies under the module packages. `tier4_planning_component.launch.xml` points at `autoware_launch`:

| Consumed by | Launch arg | File loaded onto `behavior_path_planner` |
|---|---|---|
| Goal / pull-over A* | `behavior_path_planner_goal_planner_module_param_path` | `.../behavior_path_planner/goal_planner/goal_planner.param.yaml` |
| Start / pull-out A* | `behavior_path_planner_start_planner_module_param_path` | `.../behavior_path_planner/start_planner/start_planner.param.yaml` |
| Slot order | `behavior_path_planner_scene_module_manager_param_path` | `scene_module_manager.param.yaml` |
| Vehicle geometry | `vehicle_param_file` | `$(vehicle_model)_description/config/vehicle_info.param.yaml` |
| Costmap (shared) | `costmap_generator_param_path` | `.../common/costmap_generator.param.yaml` (parking node; BPP only **subscribes** to its occupancy grid) |

Package-local copies (source-style defaults, not what `autoware.launch.xml` loads):

- `autoware_behavior_path_goal_planner_module/config/goal_planner.param.yaml`
- `autoware_behavior_path_start_planner_module/config/start_planner.param.yaml`

**Parking-scenario A* (not the two files)** uses a **different** YAML and constructor:

- `.../parking/freespace_planner/freespace_planner.param.yaml`
- keys are flat: `time_limit`, `astar.search_method`, …

Changing `goal_planner.param.yaml` / `start_planner.param.yaml` does **not** affect the parking node, and vice versa.

---

## 5. How params get from YAML into C++

ROS 2 loads the YAML onto the `behavior_path_planner` node (`<param from="...yaml"/>`). Nested YAML becomes dotted parameter names.

Then **the module managers copy fields by hand**. `AstarSearch` never reads the YAML itself in these two paths.

### Init chain

**Goal planner**

```
GoalPlannerModuleManager::init()
  → initGoalPlannerParameters(node, "goal_planner.")
      fills GoalPlannerParameters::{freespace_parking_common_parameters, astar_parameters}
  → createNewSceneModuleInstance() → GoalPlannerModule(node, parameters)
      if enable_freespace_parking:
        FreespacePullOver(node, parameters)
          → new AstarSearch(common, vehicle_shape, astar, clock)
```

**Start planner**

```
StartPlannerModuleManager::init()
  → StartPlannerParameters::init(node)
      fills StartPlannerParameters::{freespace_planner_common_parameters, astar_parameters}
  → StartPlannerModule(node, parameters)
      if enable_freespace_planner:
        FreespacePullOut(node, parameters)
          → new AstarSearch(common, vehicle_shape, astar, clock)
```

Declaration sites:

- Goal: `goal_planner_module/src/manager.cpp` (`initGoalPlannerParameters`, ns `goal_planner.pull_over.freespace_parking.*`)
- Start: `start_planner_module/src/data_structs.cpp` (`StartPlannerParameters::init`, ns `start_planner.freespace_planner.*`)

### `PlannerCommonParam` — YAML key → struct field

| Struct field | Goal YAML / ROS param | Start YAML / ROS param | Parsed in BPP C++? |
|---|---|---|---|
| `time_limit` | `...freespace_parking.time_limit` | `...freespace_planner.time_limit` | yes |
| `max_turning_ratio` | `...max_turning_ratio` | same | yes |
| `turning_steps` | `...turning_steps` | same | yes |
| `theta_size` | `...search_configs.theta_size` | same | yes |
| `angle_goal_range` | `...search_configs.angle_goal_range` | same | yes |
| `curve_weight` | `...search_configs.curve_weight` | same | yes |
| `reverse_weight` | `...search_configs.reverse_weight` | same | yes |
| `lateral_goal_range` | `...search_configs.lateral_goal_range` | same | yes |
| `longitudinal_goal_range` | `...search_configs.longitudinal_goal_range` | same | yes |
| `obstacle_threshold` | `...costmap_configs.obstacle_threshold` | same | yes |
| **`direction_change_weight`** | **`...search_configs.direction_change_weight` (1.5 in YAML)** | same | **no — stays 0** |

### `AstarParam` — YAML key → struct field

| Struct field | YAML (both modules) | Parsed in BPP C++? | Effect if missing |
|---|---|---|---|
| `search_method` | `astar.search_method` (`"forward"`) | yes | — |
| `only_behind_solutions` | `astar.only_behind_solutions` | yes | — |
| `use_back` | `astar.use_back` | yes | also copied to wrapper `use_back_` |
| `distance_heuristic_weight` | `astar.distance_heuristic_weight` | yes | — |
| **`adapt_expansion_distance`** | `true` in YAML | **no** | `false` → fixed expansion |
| **`expansion_distance`** | `0.5` | **no** | `0.0`; `setMap` then clamps to `1.5 * grid_resolution` |
| **`near_goal_distance`** | `3.0` | **no** | `0.0`; ctor uses `max(0, longitudinal_goal_range)` |
| **`smoothness_weight`** | `0.5` | **no** | `0.0` → no steering-change cost |
| **`obstacle_distance_weight`** | `1.75` | **no** | `0.0` → no obstacle-distance cost |
| **`goal_lat_distance_weight`** | `5.0` | **no** | `0.0` → no lateral-to-goal cost |

YAML still contains those keys (they sit on the parameter server), but these two modules never `declare_parameter` them into the struct. `AstarSearch` is constructed with that half-filled `AstarParam`.

The **parking node** does load the full set, because it uses the node constructor that declares `astar.search_method`, `astar.adapt_expansion_distance`, etc. That constructor is **not** used by `FreespacePullOver` / `FreespacePullOut`. They call the `(PlannerCommonParam, VehicleShape, AstarParam, clock)` overload.

### Practical takeaway for tuning

To change Hybrid A* used by **pull-over / pull-out**:

1. Edit the `autoware_launch` YAML (the files launch actually loads).
2. For fields the C++ managers actually copy (`time_limit`, `theta_size`, `use_back`, `search_method`, `distance_heuristic_weight`, …), that is enough.
3. For `adapt_expansion_distance`, `expansion_distance`, `near_goal_distance`, `smoothness_weight`, `obstacle_distance_weight`, `goal_lat_distance_weight`, and `direction_change_weight`: YAML currently does **not** reach `AstarSearch` in these two modules. Matching `declare_parameter` assignments would be needed in `goal_planner_module/src/manager.cpp` and `start_planner_module/src/data_structs.cpp`.

Default algorithm strings in both YAMLs are already `"astar"`.

---

## 6. Construction of `AstarSearch` in the two wrappers

Both:

1. Build `VehicleShape` from `VehicleInfo` + `vehicle_shape_margin`.
2. If algorithm string is `"astar"`, construct `AstarSearch` with common params + `astar_parameters`.
3. Else if `"rrtstar"`, construct `RRTStar`.

Goal (`freespace_pull_over.cpp`):

```cpp
FreespacePullOver::FreespacePullOver(...)
{
  VehicleShape vehicle_shape(vehicle_info_, parameters.vehicle_shape_margin);
  if (parameters.freespace_parking_algorithm == "astar") {
    planner_ = std::make_unique<AstarSearch>(
      parameters.freespace_parking_common_parameters, vehicle_shape, parameters.astar_parameters,
      node.get_clock());
  }
}
```

Start is the same with `freespace_planner_common_parameters`.

`AstarSearch` ctor then derives:

- `steering_resolution_ = max_steering / turning_steps`
- `heading_resolution_ = 2π / theta_size`
- `is_backward_search_ = (search_method == "backward")`
- expansion / near-goal distances from `AstarParam`

---

## 7. Construction vs use (three layers)

Launch builds the **managers**. The **modules** (and `AstarSearch` inside them) are built later, on the first BPP cycle that asks “should this module run?”. A* itself only runs as a **stuck fallback**, and only while the stack is in **lane driving**.

```
Launch (once)
  pluginlib loads StartPlannerModuleManager / GoalPlannerModuleManager
  manager::init()  → declare YAML params
                    → does NOT construct StartPlannerModule / GoalPlannerModule yet

First BPP cycle in LANEDRIVING, slot has no active instance
  manager->updateIdleModuleInstance()
    → createNewSceneModuleInstance()
        StartPlannerModule / GoalPlannerModule ctor
          if enable_freespace_*:
            FreespacePullOut / FreespacePullOver ctor
              → new AstarSearch(...)
          1 Hz timer created here

If isExecutionRequested() == true
  idle instance is moved into candidates
  registerNewModule() → onEntry()
  module run() / plan() starts
```

Idle construction (`SceneModuleManagerInterface::updateIdleModuleInstance`):

- First call: `createNewSceneModuleInstance()`.
- Later calls while idle still exists: just `onEntry()`.

`PlannerManager` only constructs idle when `canLaunchNewModule()` is true (no live observer of that type). Then it asks `isExecutionRequested()`. If false, the idle object **stays** — `AstarSearch` is already constructed, but `makePlan` is not called.

So: **A* objects exist as soon as BPP first evaluates the idle module**, which is the first lane-driving planning tick after startup. They are **used** only under the conditions below.

When a module is requested, `getIdleModule()` moves the idle pointer out. After `registerNewModule`, observers are non-empty, so `canLaunchNewModule()` is false until the instance succeeds/fails and is deleted.

---

## 8. How A* is actually run (1 Hz timer, not at launch)

A* is **not** started from launch. Launch only constructs the modules. Search runs later on a 1 Hz callback group, when the vehicle is stuck and a fresh costmap exists.

### Costmap into the node

`behavior_planning.launch.xml` remaps:

```
~/input/costmap → /planning/scenario_planning/parking/costmap_generator/occupancy_grid
```

`BehaviorPathPlannerNode` polls that into `planner_data_->costmap`. Both A* wrappers call `planner_->setMap(costmap)` immediately before `makePlan`.

`makePlan` then:

```
resetData, global2local, collision check, optional start/goal swap if backward,
setCollisionFreeDistanceMap, setStartNode, search()
waypoints → PathWithLaneId, split at reverse indices
```

---

## 9. When `start_planner` is used

Slot 1 (highest). Requested by `StartPlannerModule::isExecutionRequested()`.

It **does not** run if any of these is true:

1. Already on the ego centerline: `|lateral offset| < th_distance_to_middle_of_the_road` (**0.5 m**)
2. More than `th_arrived_distance` (**1.0 m**) from the **original route start pose**
   (`isCloseToOriginalStartPose()` is named backwards: it is true when ego has **left** the start)
3. Within 1.0 m of the **goal**
4. Still moving: speed ≥ `th_stopped_velocity` (**0.01 m/s**)
5. Goal is behind ego in the same route segment

It **does** run when ego is **stopped, off-center (≥ 0.5 m), still near the route start (≤ 1 m)**. That is pull-out from a parked/shoulder start.

Once running, **lane planners run first**. Default `search_priority` is `["CLOTHOID", "SHIFT"]`. A* is **not** in that list.

A* pull-out (`FreespacePullOut::plan`) runs only on the 1 Hz timer when **all** of:

- module status is not `IDLE`
- `enable_freespace_planner: true` (YAML default)
- costmap exists and is < 1 s old
- ego is stopped **and** the selected type is `STOP` **and** no pull-out path was found

`STOP` is set when clothoid/shift fail (`generateStopOutput()`). So A* is: **pull-out requested, geometric planners failed, vehicle stuck, parking costmap fresh**.

If A* succeeds, `updateData()` copies that path onto the main thread and `planner_type` becomes `FREESPACE`. The module stays until `hasReachedFreespaceEnd()`.

---

## 10. When `goal_planner` is used

Slot 3. Requested by `GoalPlannerModule::isExecutionRequested()`.

**Always-on gate:** goal must be reachable on the current/neighboring road path (`is_goal_reachable_on_path`). If not, the module is not requested.

Then two modes:

### A. Goal modification **not** allowed

`utils::isAllowedGoalModification(route_handler)` is:

```
route_handler->isAllowedGoalModification()  ||  original goal sits on a shoulder lanelet
```

If false, the module still requests if the goal is reachable, but `plan()` uses `DefaultFixedGoalPlanner` (centerline to the **original** goal). **Freespace is never used.** The A* timer also bails out on this flag.

### B. Goal modification **allowed** (shoulder / parking-style goal)

Request also requires:

- signed arc length to goal is in `[0, request_length]`
- `request_length` ≈ `1.2 × stop_distance + backward_goal_search_length (20 m) + approximate_pull_over_distance (20 m)`, floored by `pull_over_minimum_request_length` (0)
- previous module’s terminal pose can **cross** into the pull-over / shoulder lane (`isCrossingPossible`)

Parking policy default is `left_side`.

Lane-parking candidates (SHIFT / ARC_FORWARD / ARC_BACKWARD from `efficient_path_order`) start preparing when ego is within `pull_over_prepare_length` (**100 m**) of the goal.

**A* pull-over** (`FreespacePullOver::plan`) is again a 1 Hz stuck fallback. `FreespaceParkingPlanner::onTimer` requires **all** of:

- not `IDLE`
- `enable_freespace_parking: true`
- goal modification allowed
- costmap present and < 1 s old
- ego not already on the modified goal
- `isStuck(...)`
- path update due (≥ 1 s since last update)

`isStuck` is true if ego is **stopped** and either:

- there is **no** pull-over path yet, or
- the current path collides with objects (hard margin) or occupancy grid

Path selection prefers **lane parking**. Freespace is used only if `selectPullOverPath()` returns nothing:

```cpp
const auto lane_pull_over_path_opt = selectPullOverPath(...);
const auto & pull_over_path_opt =
  lane_pull_over_path_opt ? lane_pull_over_path_opt
                          : context_data.freespace_parking_response.freespace_pull_over_path;
```

Once a FREESPACE path is selected, it is not switched back to lane parking (`canReturnToLaneParking` returns false for FREESPACE). The module never transits SUCCESS (`canTransitSuccessState` is always false); it keeps running through the park.

If `use_back_` is false, the goal is offset 1 m longitudinally and a short interpolated straight is appended.

---

## 11. End-to-end: when A* actually `makePlan`s under default launch

```
autoware.launch.xml
  planning_setting = rule_based          else BPP never starts
  scenario = LANEDRIVING                 else BPP returns without running modules
  costmap from parking/costmap_generator must be publishing

START (pull-out A*)
  ego stopped, off centerline ≥ 0.5 m, still ≤ 1 m from route start
  clothoid/shift failed → STOP
  enable_freespace_planner true
  costmap < 1 s old
  → FreespacePullOut::plan → AstarSearch::makePlan

GOAL (pull-over A*)
  goal on shoulder OR route allows goal modification
  ego within request_length of goal, can reach pull-over lane
  lane SHIFT/ARC paths failed or blocked
  ego stopped / stuck
  enable_freespace_parking true
  costmap < 1 s old
  → FreespacePullOver::plan → AstarSearch::makePlan

PARKING scenario (not the two BPP files)
  ego in parking_lot, goal not in lane
  → FreespacePlannerNode A* instead; BPP idle
```

**Typical Autoware run on a normal road goal:** start_planner never requests (on centerline / already left start), goal_planner may request near the goal but uses lane parking or fixed-goal, **A* never runs**.

**Typical Autoware run for roadside pull-out / pull-over:** modules request as above; A* only if the geometric planners cannot produce a path and the vehicle is stuck with a live parking costmap.

---

## 12. Key source files

| Layer | Path |
|---|---|
| Top launch | `src/launcher/autoware_launch/autoware_launch/launch/autoware.launch.xml` |
| Planning component | `.../launch/components/tier4_planning_component.launch.xml` |
| Preset | `.../config/planning/preset/default_preset.yaml` |
| Scenario + parking | `tier4_planning_launch/launch/scenario_planning/{scenario_planning,parking,lane_driving}.launch.xml` |
| BPP composable node | `.../behavior_planning/behavior_planning.launch.xml` |
| Goal YAML | `.../behavior_path_planner/goal_planner/goal_planner.param.yaml` |
| Start YAML | `.../behavior_path_planner/start_planner/start_planner.param.yaml` |
| Parking YAML | `.../parking/freespace_planner/freespace_planner.param.yaml` |
| Goal param declare | `autoware_behavior_path_goal_planner_module/src/manager.cpp` |
| Start param declare | `autoware_behavior_path_start_planner_module/src/data_structs.cpp` |
| Goal A* wrapper | `.../pull_over_planner/freespace_pull_over.cpp` |
| Start A* wrapper | `.../freespace_pull_out.cpp` |
| Hybrid A* | `autoware_freespace_planning_algorithms/{include,src}/.../astar_search.{hpp,cpp}` |
| Parking node | `autoware_freespace_planner/src/.../freespace_planner_node.cpp` |
| Scenario selector | `autoware_scenario_selector/src/node.cpp` |
