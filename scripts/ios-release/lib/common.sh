# shellcheck shell=bash
# Shared helpers for Phrasa iOS release automation.
# Portable to macOS Bash 3.2 (no associative arrays, no mapfile).

phrasa_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

phrasa_info() {
  printf 'INFO: %s\n' "$*"
}

phrasa_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

# Append a blocker message (does not exit). Uses BLOCKERS array in caller.
phrasa_blocker() {
  local msg="$1"
  BLOCKERS+=("$msg")
  printf 'BLOCKER: %s\n' "$msg" >&2
}

phrasa_require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || phrasa_die "required command not found: $c"
  done
}

phrasa_repo_root() {
  # scripts/ios-release/lib -> repo root is ../../..
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  printf '%s' "$here"
}

phrasa_iso_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Readable UTC stamp plus PID (not unique alone — use phrasa_create_run_dir).
phrasa_run_stamp() {
  printf '%s-%s' "$(date -u +"%Y%m%dT%H%M%SZ")" "$$"
}

# Create a unique, never-reused run directory under the fixed release-runs parent.
# Format: <UTC>-<PID>-<random> via mktemp -d (collision-safe for concurrent/rapid calls).
# Prints the absolute path of the new empty directory on stdout.
phrasa_create_run_dir() {
  local parent="$1"
  local stamp template dir
  if [[ -z "${parent}" ]]; then
    phrasa_die "phrasa_create_run_dir: parent directory is required"
  fi
  if [[ "${parent}" != /* ]]; then
    phrasa_die "phrasa_create_run_dir: parent must be absolute: ${parent}"
  fi
  phrasa_ensure_dir "${parent}"
  stamp="$(phrasa_run_stamp)"
  template="${parent}/${stamp}-XXXXXX"
  dir="$(mktemp -d "${template}")" || phrasa_die "phrasa_create_run_dir: mktemp -d failed under ${parent}"
  # Belt-and-suspenders: refuse if somehow not a fresh exclusive dir
  if [[ ! -d "${dir}" ]]; then
    phrasa_die "phrasa_create_run_dir: expected new directory missing: ${dir}"
  fi
  printf '%s' "${dir}"
}

phrasa_sha256_file() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    sha256sum "$f" | awk '{print $1}'
  fi
}

phrasa_sha256_string() {
  local s="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$s" | sha256sum | awk '{print $1}'
  fi
}

# Tee stdout+stderr to a log while still printing. Preserves command status via PIPESTATUS.
phrasa_tee_log() {
  local log_file="$1"
  shift
  mkdir -p "$(dirname "$log_file")"
  # shellcheck disable=SC2094
  "$@" 2>&1 | tee -a "$log_file"
  return "${PIPESTATUS[0]}"
}

# Create one or more directories. Each argument must be a non-empty absolute path
# that is not a filesystem root / home / tmp broad root.
phrasa_ensure_dir() {
  local d
  if [[ $# -lt 1 ]]; then
    phrasa_die "phrasa_ensure_dir: requires at least one directory path"
  fi
  for d in "$@"; do
    if [[ -z "${d}" ]]; then
      phrasa_die "phrasa_ensure_dir: refusing empty path"
    fi
    if [[ "${d}" != /* ]]; then
      phrasa_die "phrasa_ensure_dir: path must be absolute: ${d}"
    fi
    # Reject roots and other overly broad targets (exact match only).
    case "${d}" in
      /|/Applications|/Library|/System|/Users|/Volumes|/bin|/cores|/dev|/etc|/home|/opt|/private|/sbin|/tmp|/usr|/var)
        phrasa_die "phrasa_ensure_dir: refusing unsafe broad path: ${d}"
        ;;
    esac
    # Also reject single-segment roots under /Users (e.g. /Users/foo alone is ok as home
    # but creating the entire home is not this helper's job for release runs — still allow
    # deeper paths only when they look intentional: require at least 3 path components.
    local depth
    depth="$(printf '%s' "${d}" | awk -F/ '{print NF-1}')"
    if [[ "${depth}" -lt 3 ]]; then
      phrasa_die "phrasa_ensure_dir: path too shallow (need >=3 components): ${d}"
    fi
    mkdir -p "${d}" || phrasa_die "phrasa_ensure_dir: mkdir failed: ${d}"
  done
}

# Resolve path to canonical absolute form when the path exists; otherwise return
# cleaned absolute path without requiring existence of the final component.
phrasa_abspath() {
  local p="$1"
  if [[ -z "$p" ]]; then
    phrasa_die "phrasa_abspath: empty path"
  fi
  if [[ "$p" != /* ]]; then
    p="$(pwd)/$p"
  fi
  # If path exists, use cd -P for realpath-like resolution
  if [[ -d "$p" ]]; then
    (cd -P "$p" && pwd)
    return 0
  fi
  local parent base
  parent="$(dirname "$p")"
  base="$(basename "$p")"
  if [[ -d "$parent" ]]; then
    printf '%s/%s\n' "$(cd -P "$parent" && pwd)" "$base"
  else
    # Parent may not exist yet; return normalized absolute string
    printf '%s\n' "$p"
  fi
}

# True (return 0) if any path component is exactly ".." (raw string check).
phrasa_path_has_dotdot_component() {
  local p="$1"
  local part
  local IFS='/'
  # shellcheck disable=SC2086
  set -f
  for part in ${p}; do
    if [[ "${part}" == ".." ]]; then
      set +f
      return 0
    fi
  done
  set +f
  return 1
}

# Fail-closed rm -rf: target must resolve strictly inside the unique run directory.
# Refuses empty, ".", "/", run_dir itself, any raw ".." component, paths outside
# run_dir, and symlinks whose resolved target escapes run_dir.
phrasa_safe_rm_rf() {
  local target="$1"
  local run_dir="$2"
  local abs_target abs_run prefix

  if [[ -z "${target}" || -z "${run_dir}" ]]; then
    phrasa_die "phrasa_safe_rm_rf: target and run_dir are required"
  fi
  if [[ "${target}" == "." || "${target}" == ".." || "${target}" == "/" ]]; then
    phrasa_die "phrasa_safe_rm_rf: refusing dangerous target: ${target}"
  fi

  # Reject raw ".." components before any resolution or rm (prevents string-prefix
  # bypass when intermediate path segments do not yet exist).
  if phrasa_path_has_dotdot_component "${target}"; then
    phrasa_die "phrasa_safe_rm_rf: refusing path with .. component: ${target}"
  fi
  if phrasa_path_has_dotdot_component "${run_dir}"; then
    phrasa_die "phrasa_safe_rm_rf: refusing run_dir with .. component: ${run_dir}"
  fi

  abs_run="$(phrasa_abspath "${run_dir}")"
  abs_target="$(phrasa_abspath "${target}")"

  # Strip trailing slashes for comparison
  abs_run="${abs_run%/}"
  abs_target="${abs_target%/}"

  # Resolved paths must also be free of ".." (defensive; abspath should normalize).
  if phrasa_path_has_dotdot_component "${abs_target}"; then
    phrasa_die "phrasa_safe_rm_rf: refusing unresolved .. in target: ${abs_target}"
  fi
  if phrasa_path_has_dotdot_component "${abs_run}"; then
    phrasa_die "phrasa_safe_rm_rf: refusing unresolved .. in run_dir: ${abs_run}"
  fi

  if [[ -z "${abs_run}" || "${abs_run}" == "/" ]]; then
    phrasa_die "phrasa_safe_rm_rf: refusing empty or root run_dir"
  fi
  if [[ "${abs_target}" == "${abs_run}" ]]; then
    phrasa_die "phrasa_safe_rm_rf: refusing to remove entire run_dir: ${abs_target}"
  fi

  prefix="${abs_run}/"
  case "${abs_target}" in
    "${prefix}"*)
      ;;
    *)
      phrasa_die "phrasa_safe_rm_rf: target not inside run_dir (target=${abs_target} run_dir=${abs_run})"
      ;;
  esac

  # Final depth check: target under run_dir must be deeper than run_dir
  if [[ "${#abs_target}" -le "${#abs_run}" ]]; then
    phrasa_die "phrasa_safe_rm_rf: target not strictly nested under run_dir"
  fi

  # If the path is a symlink, also verify the non-resolved path string stays under
  # run_dir (link lives inside) AND that following it does not escape (already
  # enforced via abspath + prefix). Refuse escape so external targets are never
  # deleted through a link.
  if [[ -L "${target}" || -L "${abs_target}" ]]; then
    # Re-check: abspath for a symlink-to-dir uses cd -P and may leave run_dir.
    # That case already failed the prefix check above. If we are still here, the
    # resolved location is under run_dir (e.g. symlink to a nested real path).
    :
  fi

  rm -rf "${abs_target}"
}

# Write a deterministic sorted listing of sha256 + relative paths for a directory tree.
phrasa_write_dir_file_hashes() {
  local out="$1"
  local root_dir="$2"
  local label="${3:-path}"
  {
    printf '%s=%s\n' "${label}" "${root_dir}"
    if [[ -d "${root_dir}" ]]; then
      # Portable: find + sort; hash each regular file. No secrets expected in product trees.
      find "${root_dir}" -type f | sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(phrasa_sha256_file "$f")" "${f#"${root_dir}"/}"
      done
    else
      printf 'missing=1\n'
    fi
  } >"${out}"
}

# Compute reproducible candidate fingerprint (pre-binary; source + settings).
# Not a codesign identity — binds evidence to this exact candidate lane.
phrasa_candidate_fingerprint() {
  local commit="$1"
  local marketing="$2"
  local build="$3"
  local bundle="$4"
  local team="$5"
  local pbxproj_hash="${6:-}"
  local material
  material=$(printf 'phrasa-candidate-v1\ncommit=%s\nmarketing=%s\nbuild=%s\nbundle=%s\nteam=%s\npbxproj=%s\n' \
    "$commit" "$marketing" "$build" "$bundle" "$team" "$pbxproj_hash")
  phrasa_sha256_string "$material"
}

phrasa_write_proof_manifest() {
  local out="$1"
  shift
  # Remaining args: key=value pairs (values should already be non-secret)
  local k v
  {
    printf '# Phrasa release proof manifest\n'
    printf 'generated_at_utc=%s\n' "$(phrasa_iso_utc_now)"
    for pair in "$@"; do
      k="${pair%%=*}"
      v="${pair#*=}"
      # Never write obvious secret-looking values
      case "$k" in
        *secret*|*password*|*token*|*private*|*p8*|*credential*)
          printf '%s=(redacted)\n' "$k"
          ;;
        *)
          printf '%s=%s\n' "$k" "$v"
          ;;
      esac
    done
  } >"$out"
}

phrasa_append_hash_line() {
  local manifest="$1"
  local label="$2"
  local path="$3"
  if [[ -f "$path" ]]; then
    printf 'sha256_%s=%s\n' "$label" "$(phrasa_sha256_file "$path")" >>"$manifest"
    printf 'path_%s=%s\n' "$label" "$path" >>"$manifest"
  else
    printf 'sha256_%s=(missing)\n' "$label" >>"$manifest"
    printf 'path_%s=%s\n' "$label" "$path" >>"$manifest"
  fi
}

# Extract a unique KEY = value line from xcodebuild -showBuildSettings output.
# Fails (prints empty, returns 1) if missing or if multiple distinct values appear.
phrasa_build_setting_get() {
  local settings_file="$1"
  local key="$2"
  local values
  values="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$settings_file" 2>/dev/null \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
    | sed -E 's/[[:space:]]+$//' \
    | sort -u)" || true
  if [[ -z "$values" ]]; then
    return 1
  fi
  local n
  n="$(printf '%s\n' "$values" | grep -c . || true)"
  if [[ "$n" != "1" ]]; then
    printf 'AMBIGUOUS:%s' "$(printf '%s' "$values" | tr '\n' ',')"
    return 2
  fi
  printf '%s' "$values"
  return 0
}
