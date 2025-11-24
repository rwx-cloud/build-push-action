#!/bin/bash
set -euo pipefail

get_latest_v2_version() {
  local api_url="https://api.github.com/repos/rwx-cloud/cli/releases"
  local latest_version
  
  local releases_json
  if ! releases_json=$(curl -fsSL "$api_url" 2>/dev/null); then
    echo "Warning: Could not fetch releases from GitHub API, falling back to v2.1.0" >&2
    echo "v2.1.0"
    return
  fi
  
  if command -v jq >/dev/null 2>&1; then
    latest_version=$(echo "$releases_json" | jq -r \
      '[.[] | select(.tag_name | startswith("v2.")) | .tag_name] | sort_by(. | ltrimstr("v") | split(".") | map(tonumber)) | last' 2>/dev/null)
  else
    latest_version=$(echo "$releases_json" | \
      grep -oE '"tag_name":\s*"v[0-9]+\.[0-9]+\.[0-9]+"' | \
      sed 's/"tag_name":\s*"\(.*\)"/\1/' | \
      grep -E '^v2\.' | \
      sort -V | \
      tail -1)
  fi
  
  echo "$latest_version"
}

install_rwx_cli() {
  local version="$1"
  local os arch
  
  case "$(uname -s)" in
    Linux*) os="linux" ;;
    Darwin*) os="darwin" ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac
  
  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  
  local binary_name="rwx-${os}-${arch}"
  local download_url="https://github.com/rwx-cloud/cli/releases/download/${version}/${binary_name}"
  local tmp_file
  
  tmp_file="$(mktemp -d)/rwx"
  echo "Downloading RWX CLI from ${download_url}..."
  curl -o "${tmp_file}" -fsSL "${download_url}"
  chmod +x "${tmp_file}"
  
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo install "${tmp_file}" /usr/local/bin/rwx
  else
    mkdir -p ~/.local/bin
    install "${tmp_file}" ~/.local/bin/rwx
    export PATH="$HOME/.local/bin:$PATH"
  fi
  rm "${tmp_file}"
  
  echo "RWX CLI installed:"
  rwx --version
}

parse_init_params() {
  local init_input="$1"
  local init_args=()
  
  if [ -z "$init_input" ]; then
    return
  fi
  
  if command -v jq >/dev/null 2>&1; then
    if echo "$init_input" | jq -e . >/dev/null 2>&1; then
      while IFS= read -r line; do
        if [ -n "$line" ]; then
          init_args+=("--init" "$line")
        fi
      done < <(echo "$init_input" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
      printf '%s\n' "${init_args[@]}"
      return
    fi
  fi
  
  # non-json init parameters
  IFS=',' read -ra PARAMS <<< "$init_input"
  for param in "${PARAMS[@]}"; do
    param=$(echo "$param" | xargs) # trim whitespace
    if [ -n "$param" ]; then
      init_args+=("--init" "$param")
    fi
  done
  
  printf '%s\n' "${init_args[@]}"
}

parse_push_to() {
  local push_to_input="$1"
  
  if [ -z "$push_to_input" ]; then
    return
  fi
  
  push_to_input=$(echo "$push_to_input" | xargs)
  if [ -n "$push_to_input" ]; then
    printf '%s\n' "--push-to"
    printf '%s\n' "$push_to_input"
  fi
}

extract_image_reference() {
  local output="$1"
  local image_ref
  # Match the RWX image URL pattern: cloud.rwx.com/*:hexstring
  image_ref=$(echo "$output" | grep -oE 'cloud\.rwx\.com/[^/:]+:[a-f0-9]{32}' | head -1)
  echo "$image_ref"
}

main() {
  local file target init push_to
  local pull cache timeout
  local build_args=()
  local output_json image_ref run_url
  
  file="${INPUT_FILE}"
  target="${INPUT_TARGET:-}"
  init="${INPUT_INIT:-}"
  push_to="${INPUT_PUSH_TO:-}"
  pull="${INPUT_PULL:-false}"
  cache="${INPUT_CACHE:-true}"
  timeout="${INPUT_TIMEOUT:-30m}"
  
  if [ -z "$file" ]; then
    echo "Error: 'file' input is required" >&2
    exit 1
  fi
  
  if [ -z "$target" ]; then
    echo "Error: 'target' input is required" >&2
    exit 1
  fi
  
  local rwx_cli_version
  rwx_cli_version=$(get_latest_v2_version)
  
  install_rwx_cli "$rwx_cli_version"
  
  if [ -z "${RWX_ACCESS_TOKEN:-}" ]; then
    echo "Error: RWX_ACCESS_TOKEN environment variable is required" >&2
    exit 1
  fi
  export RWX_ACCESS_TOKEN
  
  if [ -n "$push_to" ]; then
    echo "Pushing to registry: ${push_to}"
    
    local docker_config="${HOME}/.docker/config.json"
    if [ ! -f "$docker_config" ] || [ ! -s "$docker_config" ]; then
      echo "Error: Docker config not found at ${docker_config}" >&2
      echo "This usually means Docker was not authenticated to the registry." >&2
      echo "Please add a step before this one to authenticate using docker/login-action." >&2
      echo "See the rwx-cloud/build-push-action README for more details." >&2
      exit 1
    fi
  fi
  
  build_args=("image" "build" "$file")
  
  build_args+=("--target" "$target")
  
  if [ -n "$init" ]; then
    while IFS= read -r arg; do
      if [ -n "$arg" ]; then
        build_args+=("$arg")
      fi
    done < <(parse_init_params "$init")
  fi
  
  if [ -n "$push_to" ]; then
    while IFS= read -r arg; do
      if [ -n "$arg" ]; then
        build_args+=("$arg")
      fi
    done < <(parse_push_to "$push_to")
  fi
  
  if [ "$pull" = "false" ]; then
    build_args+=("--no-pull")
  fi
  
  if [ "$cache" = "false" ]; then
    build_args+=("--no-cache")
  fi
  
  if [ -n "$timeout" ]; then
    build_args+=("--timeout" "$timeout")
  fi
  
  echo "Running: rwx ${build_args[*]}"
  
  local output_file
  output_file=$(mktemp)
  
  if ! rwx "${build_args[@]}" 2>&1 | tee "$output_file"; then
    build_output=$(cat "$output_file")
    rm -f "$output_file"
    echo "Build failed:" >&2
    echo "$build_output" >&2
    exit 1
  fi
  
  build_output=$(cat "$output_file")
  rm -f "$output_file"
  
  local extracted_image_ref
  extracted_image_ref=$(extract_image_reference "$build_output")
  
  run_url=$(echo "$build_output" | grep -oE 'https://cloud\.rwx\.com/[^[:space:]]+' | head -1 || echo "")
  
  if [ -n "$push_to" ]; then
    image_ref=$(echo "$push_to" | xargs)
  elif [ -n "$extracted_image_ref" ]; then
    image_ref="$extracted_image_ref"
  fi
  
  if command -v jq >/dev/null 2>&1; then
    output_json=$(jq -n \
      --arg image_ref "$image_ref" \
      --arg run_url "$run_url" \
      --arg raw_output "$build_output" \
      '{
        image_reference: $image_ref,
        run_url: $run_url,
        raw_output: $raw_output
      }')
  else
    output_json="{\"image_reference\":\"$image_ref\",\"run_url\":\"$run_url\"}"
  fi
  
  if [ -n "$image_ref" ]; then
    echo "image-reference=${image_ref}" >> "$GITHUB_OUTPUT"
  fi
  
  if [ -n "$run_url" ]; then
    echo "run-url=${run_url}" >> "$GITHUB_OUTPUT"
  fi
  
  echo "json<<EOF" >> "$GITHUB_OUTPUT"
  echo "$output_json" >> "$GITHUB_OUTPUT"
  echo "EOF" >> "$GITHUB_OUTPUT"
  
  echo "Build completed successfully!"
  echo "Image Reference: ${image_ref}"
  if [ -n "$run_url" ]; then
    echo "Run URL: ${run_url}"
  fi
}

main
