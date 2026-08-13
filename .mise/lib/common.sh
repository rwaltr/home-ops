# shellcheck shell=bash
# Shared helpers for mise tasks. Source from task scripts:
#   source "${MISE_PROJECT_ROOT}/.mise/lib/common.sh"

# Structured log line prefixed with the calling task's name.
log() { echo "[${MISE_TASK_NAME:-task}] $*"; }

# Log an error and exit.
die() {
  log "ERROR: $*" >&2
  exit 1
}

# Download an artifact with checksum verification.
#
# Usage:
#   download_artifact <url> <sha256|sha512|https-checksum-url> <dest>
#
# The second argument may be a literal sha256/sha512 hex string or an https://
# URL to a checksum: a bare hash, a "hash  filename" line, or a multi-line
# checksums/DIGESTS file containing the artifact's filename. When multiple
# hash types are published for the same file, the strongest is used
# (sha512 > sha256; md5/sha1 are ignored).
#
# Use this instead of relying on mise `outputs` caching alone — outputs can
# go stale or be truncated/corrupt on disk while mise still skips the task.
#
# Exits 0 when <dest> is in place and verified, whether downloaded fresh or
# already present (reported as done either way). Exits 1 on any failure:
# network errors, checksum mismatch, or bad arguments (that's on us).
# Downloads are atomic: partial files never land at <dest>.
download_artifact() {
  local url="$1" sha_ref="$2" dest="$3"
  local filename expected_sha tmp_file

  filename=$(basename "${url}")

  # Resolve the expected checksum
  if [[ "${sha_ref}" == https://* ]]; then
    local sha_content
    sha_content=$(curl -sfL "${sha_ref}") || die "Failed to fetch checksum from ${sha_ref}"
    expected_sha=$(awk -v f="${filename}" '
      $NF == f || $NF == "*" f {
        if ($1 ~ /^[0-9a-fA-F]{128}$/) sha512 = $1
        else if ($1 ~ /^[0-9a-fA-F]{64}$/) sha256 = $1
        next
      }
      NF == 1 && $1 ~ /^[0-9a-fA-F]{128}$/ { sha512 = $1; next }
      NF == 1 && $1 ~ /^[0-9a-fA-F]{64}$/ { sha256 = $1; next }
      END {
        if (sha512) print sha512
        else if (sha256) print sha256
        else exit 1
      }
    ' <<<"${sha_content}") || die "Could not find a sha256/sha512 for ${filename} in ${sha_ref}"
  elif [[ "${sha_ref}" == http://* ]]; then
    die "Refusing insecure checksum URL (use https): ${sha_ref}"
  else
    expected_sha="${sha_ref}"
  fi

  local sum_cmd
  case ${#expected_sha} in
    64)  sum_cmd="sha256sum" ;;
    128) sum_cmd="sha512sum" ;;
    *)   die "Invalid checksum '${expected_sha}' for ${url} (expected sha256 or sha512)" ;;
  esac
  [[ "${expected_sha}" =~ ^[0-9a-fA-F]+$ ]] || die "Invalid checksum '${expected_sha}' for ${url} (not hex)"

  # Already have a verified copy? Then we're done.
  if [[ -f "${dest}" ]] && echo "${expected_sha}  ${dest}" | ${sum_cmd} --check --status 2>/dev/null; then
    log "✓ Artifact already present and verified: ${dest}"
    return 0
  fi
  [[ -f "${dest}" ]] && log "Existing file failed checksum verification, re-downloading: ${dest}"

  mkdir -p "$(dirname "${dest}")"
  tmp_file=$(mktemp "$(dirname "${dest}")/.download.XXXXXX")

  log "Downloading ${url}"
  if ! curl -fL --retry 5 --retry-delay 5 --retry-all-errors -o "${tmp_file}" "${url}"; then
    rm -f "${tmp_file}"
    die "Download failed: ${url}"
  fi

  if ! echo "${expected_sha}  ${tmp_file}" | ${sum_cmd} --check --status; then
    rm -f "${tmp_file}"
    die "Downloaded file failed checksum verification: ${url}"
  fi

  mv -f "${tmp_file}" "${dest}"
  log "✓ Downloaded and verified: ${dest}"
}

# Flatcar test-VM host registry. Add new hosts here when adding
# infra/flatcar/butane/hosts/<host>.bu + infra/k0s/<host>.yaml.
#
# Prints "<ssh_port> <api_port>" — host-side qemu user-net forwards:
#   127.0.0.1:<ssh_port>  → VM :22
#   127.0.0.1:<api_port>  → VM :6443
vm_ports() {
  case "$1" in
    test)  echo "2223 6443" ;;
    mouse) echo "2224 16443" ;;
    *) die "Unknown flatcar host '$1' (add it to vm_ports in .mise/lib/common.sh)" ;;
  esac
}

# SSH user for a flatcar test-VM host (matches the host's butane/k0s config)
vm_user() {
  case "$1" in
    test)  echo "core" ;;
    mouse) echo "rwaltr" ;;
    *) die "Unknown flatcar host '$1' (add it to vm_user in .mise/lib/common.sh)" ;;
  esac
}


