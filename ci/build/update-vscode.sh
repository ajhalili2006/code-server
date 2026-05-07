#!/usr/bin/env bash

set -Eeuo pipefail

function remove_patches() {
  local -i exit_code=0
  quilt pop -af || exit_code=$?
  case $exit_code in
    # Sucessfully removed.
    0) ;;
    # No more patches to remove.
    2) ;;
    # Some error.
    *) return $exit_code ;;
  esac
}

function update_vscode() {
  pushd lib/vscode
  if ! git checkout "$target_vscode_version" ; then
    echo "$target_vscode_version does not exist locally, fetching..."
    git fetch --all --prune
    git checkout "$target_vscode_version"
  fi
  popd
}

function refresh_patches() {
  local -i exit_code=0
  while quilt push ; ! (( exit_code=$? )) ; do
    quilt refresh
    echo # Extra new line for separation.
  done
  case $exit_code in
    # No more patches to apply.
    2) ;;
    # Some error.
    *) return $exit_code ;;
  esac
}

function update_node() {
  local node_version
  node_version=$(cat .node-version)
  if [[ $node_version == "$target_node_version" ]] ; then
    echo "$node_version already matches $target_node_version"
  else
    echo "Updating from $node_version to $target_node_version..."
    echo "$target_node_version" > .node-version
  fi
}

function get-webview-script-hash() {
  local html
  html=$(<"$1")
  local start_tag='<script async type="module">'
  local end_tag="</script>"
  html=${html##*"$start_tag"}
  html=${html%%"$end_tag"*}
  echo -n "$html" | openssl sha256 -binary | openssl base64
}

function update_csp() {
  local -i exit_code=0
  # Move back to the webview patch so it can be refreshed.
  quilt pop webview || exit_code=$?
  case $exit_code in
    # Successfully moved.
    0) ;;
    # Already at the patch.
    2) ;;
    # Some error.
    *) return $exit_code ;;
  esac
  local file=lib/vscode/src/vs/workbench/contrib/webview/browser/pre/index.html
  local hash
  hash=$(get-webview-script-hash "$file")
  echo "Calculated hash as $hash"
  # Use octothorpe as a delimiter since the hash may contain a slash.
  sed -i.bak "s#script-src 'sha256-[^']\+'#script-src 'sha256-$hash'#" "$file"
  quilt refresh
  # Get patched back up.
  quilt push -a
}

function run() {
  local -i failed=0
  rm -f .cache/checklist
  while (( $# )) ; do
    local name=$1 ; shift
    local fn=$1 ; shift
    # Only run if an earlier step has not failed.
    if [[ $failed == 0 ]] ; then
      echo "[+] $name..."
      if $fn ; then
        echo "- [X] $name" >> .cache/checklist
      else
        ((failed++))
      fi
    fi
    # For all failed steps, write out an empty checkbox.
    if [[ $failed != 0 ]] ; then
      echo "- [ ] $name" >> .cache/checklist
    fi
  done
  if [[ $failed != 0 ]] ; then
    return 1
  fi
}

function add_changelog() {
  local file=CHANGELOG.md
  if grep "Code $target_vscode_version" "$file" ; then
    echo "Changelog for $target_vscode_version already exists"
  else
    # TODO: This is not exactly robust.  In particular, it needs to handle if
    # there is already a "changed" section.
    sed -i.bak "s/## Unreleased/## Unreleased\n\nCode v$target_vscode_version\n\n### Changed\n\n- Update to Code $target_vscode_version/" "$file"
  fi
}

function main() {
  cd "$(dirname "${0}")/../.."

  source ./ci/lib.sh

  local target_node_version
  target_node_version=$(grep target lib/vscode/remote/.npmrc | awk -F= '{print $2}' | tr -d '"')

  local target_vscode_version
  target_vscode_version="${VERSION#v}"

  declare -a steps
  # Removing patches only needs to be done locally; in CI we start from a fresh
  # clone each time.
  if [[ ! ${CI-} ]] ; then
    steps+=("Remove patches" "remove_patches")
  fi

  steps+=(
    "Update VS Code to $target_vscode_version" "update_vscode"
    "Refresh VS Code patches" "refresh_patches"
    "Set Node version to $target_node_version" "update_node"
    "Update CSP webview hash" "update_csp"
    "Add changelog note" "add_changelog"
  )

  run "${steps[@]}"

  # This step is always manual.
  echo "- [ ] Verify changelog" >> .cache/checklist
}

main "$@"
