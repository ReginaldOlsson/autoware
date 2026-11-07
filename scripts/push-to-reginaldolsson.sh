#!/usr/bin/env bash
# Fork missing repos under ReginaldOlsson, disable GitHub Actions, push local
# branches, and rewrite repositories/autoware.repos URLs to ReginaldOlsson.
set -euo pipefail
export PATH="${HOME}/.local/bin:${PATH}"

OWNER=ReginaldOlsson
ROOT=/home/mosal/autoware
cd "${ROOT}"

if ! gh auth status -h github.com >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated."
  echo "Run one of:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo "  gh auth login -h github.com -p ssh -w"
  echo "or"
  echo "  printf '%s' \"\$GITHUB_TOKEN\" | gh auth login --with-token -h github.com"
  exit 1
fi

LOGIN="$(gh api user --jq .login)"
if [[ "${LOGIN}" != "${OWNER}" ]]; then
  echo "ERROR: authenticated as '${LOGIN}', expected '${OWNER}'"
  exit 1
fi

disable_actions() {
  local repo="$1"
  echo "  disabling Actions on ${OWNER}/${repo} ..."
  # -F sends a real JSON boolean; -f would send the string "false" (HTTP 422).
  gh api -X PUT "repos/${OWNER}/${repo}/actions/permissions" \
    -F enabled=false >/dev/null
}

ensure_fork() {
  local upstream="$1"
  local name="$2"
  if gh repo view "${OWNER}/${name}" >/dev/null 2>&1; then
    echo "  fork exists: ${OWNER}/${name}"
  else
    echo "  forking ${upstream} -> ${OWNER}/${name} ..."
    gh repo fork "${upstream}" --fork-name "${name}" --clone=false
    # Fork creation can lag briefly before the repo is addressable.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if gh repo view "${OWNER}/${name}" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
  fi
  disable_actions "${name}"
}

add_me_remote() {
  local path="$1"
  local name="$2"
  local url="git@github.com:${OWNER}/${name}.git"
  if git -C "${path}" remote get-url me >/dev/null 2>&1; then
    git -C "${path}" remote set-url me "${url}"
  else
    git -C "${path}" remote add me "${url}"
  fi
}

push_branch() {
  local path="$1"
  local branch="$2"
  local local_sha remote_sha
  local_sha="$(git -C "${path}" rev-parse HEAD)"
  remote_sha="$(git ls-remote me "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')"
  if [[ "${local_sha}" == "${remote_sha}" ]]; then
    echo "  already synced ${branch} @ ${local_sha:0:8}"
    git -C "${path}" branch --set-upstream-to="me/${branch}" "${branch}" >/dev/null 2>&1 || true
    return 0
  fi
  echo "  pushing ${branch} from ${path} ..."
  if ! git -C "${path}" push -u me "${branch}"; then
    echo "  push reported an error; checking whether remote already matches ..."
    remote_sha="$(git ls-remote me "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')"
    if [[ "${local_sha}" == "${remote_sha}" ]]; then
      echo "  remote already has ${local_sha:0:8}; continuing"
      return 0
    fi
    return 1
  fi
}

echo "== Ensuring forks (Actions disabled) =="
ensure_fork autowarefoundation/autoware              autoware
ensure_fork autowarefoundation/autoware_universe     autoware_universe
ensure_fork autowarefoundation/autoware_launch       autoware_launch
ensure_fork autowarefoundation/transport_drivers     transport_drivers
ensure_fork autowarefoundation/bevdet_vendor         bevdet_vendor
ensure_fork autowarefoundation/autoware_vision_pilot autoware_vision_pilot

# Repos already under ReginaldOlsson — still disable Actions.
for existing in rko_lio lie_lane_detection boreas_cpp point_painter rviz_satellite; do
  if gh repo view "${OWNER}/${existing}" >/dev/null 2>&1; then
    disable_actions "${existing}"
  fi
done

echo "== Configuring remotes + pushing =="
add_me_remote "${ROOT}"                                             autoware
add_me_remote "${ROOT}/src/universe/autoware_universe"              autoware_universe
add_me_remote "${ROOT}/src/launcher/autoware_launch"                autoware_launch
add_me_remote "${ROOT}/src/sensor_component/transport_drivers"      transport_drivers
add_me_remote "${ROOT}/src/universe/external/bevdet_vendor"         bevdet_vendor
add_me_remote "${ROOT}/src/universe/external/autoware_vision_pilot" autoware_vision_pilot
add_me_remote "${ROOT}/src/universe/external/localization/rko_lio"  rko_lio
add_me_remote "${ROOT}/src/universe/external/lie_lane_detection"    lie_lane_detection

push_branch "${ROOT}"                                             feature/moveit-ackermann-freespace
push_branch "${ROOT}/src/universe/autoware_universe"              feature/moveit-ackermann-freespace
push_branch "${ROOT}/src/launcher/autoware_launch"                feature/moveit-ackermann-freespace
push_branch "${ROOT}/src/sensor_component/transport_drivers"      fix/local-workspace
push_branch "${ROOT}/src/universe/external/bevdet_vendor"         fix/local-workspace
push_branch "${ROOT}/src/universe/external/autoware_vision_pilot" fix/local-workspace
push_branch "${ROOT}/src/universe/external/localization/rko_lio"  fix/local-workspace
push_branch "${ROOT}/src/universe/external/lie_lane_detection"    feature/boreas-odom-mosaic-hybrid-road-seg

echo "== Rewriting repositories/autoware.repos URLs to ${OWNER} =="
python3 - <<'PY'
from pathlib import Path

path = Path("/home/mosal/autoware/repositories/autoware.repos")
text = path.read_text()
replacements = {
    "https://github.com/autowarefoundation/autoware_universe.git":
        "https://github.com/ReginaldOlsson/autoware_universe.git",
    "https://github.com/autowarefoundation/autoware_launch.git":
        "https://github.com/ReginaldOlsson/autoware_launch.git",
    "https://github.com/autowarefoundation/bevdet_vendor.git":
        "https://github.com/ReginaldOlsson/bevdet_vendor.git",
    "https://github.com/autowarefoundation/transport_drivers":
        "https://github.com/ReginaldOlsson/transport_drivers.git",
    "https://github.com/autowarefoundation/autoware_vision_pilot.git":
        "https://github.com/ReginaldOlsson/autoware_vision_pilot.git",
}
for old, new in replacements.items():
    text = text.replace(old, new)
path.write_text(text)
print("updated", path)
PY

echo
echo "DONE forks/pushes."
echo "If repositories/autoware.repos is dirty, commit + push it:"
echo "  cd ${ROOT}"
echo "  git add repositories/autoware.repos"
echo "  git commit -m 'chore(repos): point locked packages at ReginaldOlsson forks'"
echo "  git push me feature/moveit-ackermann-freespace"
echo
echo "Verify Actions are disabled, e.g.:"
echo "  gh api repos/${OWNER}/autoware_universe/actions/permissions"
