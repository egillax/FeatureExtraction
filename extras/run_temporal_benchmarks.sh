#!/usr/bin/env bash

# Benchmark temporal covariate extraction across multiple branches.
#
# The script will:
#   * Ensure worktrees exist for each target branch
#   * Build the Java jar and refresh the checksum
#   * Install the R package for that branch
#   * Run the DuckDB benchmark script under /usr/bin/time -v
#   * Capture full logs per branch and append a tabular summary
#
# Usage (from repo root):
#   scripts/run_temporal_benchmarks.sh              # default branches
#   scripts/run_temporal_benchmarks.sh main feature # custom order/list
#
# Required environment variables (pass via export before running):
#   DUCKDB_BENCHMARK_DB  - absolute path to the DuckDB file (default: ~/database/database-1M_filtered.duckdb)
#   CDM_SCHEMA           - optional (default: main)
#   COHORT_SCHEMA        - optional (default: cohorts)
#   COHORT_TABLE         - optional (default: dlc_cohorts)
#
# The benchmark script defaults to extras/benchmark_temporal_duckdb.R in each
# branch. Adjust BENCHMARK_SCRIPT below if you keep the script elsewhere.

set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)
WORKTREE_ROOT="${ROOT_DIR}/worktrees"
LOG_DIR="${ROOT_DIR}/benchmark-output"
BENCHMARK_SCRIPT_REL="extras/benchmark_temporal_duckdb.R"

# Allow custom branch list on the command line, otherwise default to the three of interest.
if [[ $# -gt 0 ]]; then
  BRANCHES=("$@")
else
  BRANCHES=("main" "optimize-temporal-consecutive" "optimize-temporal-join")
fi

mkdir -p "${WORKTREE_ROOT}" "${LOG_DIR}"

SUMMARY_FILE="${LOG_DIR}/summary.tsv"
echo -e "branch\tcommit\tbenchmark_path\tbenchmark_elapsed_s\ttime_elapsed\tpeak_rss_kb" > "${SUMMARY_FILE}"

ensure_worktree() {
  local branch="$1"
  local worktree="$2"

  if [[ "${branch}" == "main" ]]; then
    # main lives in the root directory; nothing to add
    return
  fi

  if [[ ! -d "${worktree}" ]]; then
    echo "[info] adding worktree for ${branch} -> ${worktree}" >&2
    git worktree add "${worktree}" "${branch}"
  fi
}

compute_checksum() {
  local jar_path="$1"
  Rscript -e "library(rJava); .jinit(); .jaddClassPath('${jar_path}'); .jaddClassPath('inst/java/json-20231013.jar'); .jaddClassPath('inst/java/SqlRender-1.19.1.jar'); cat(rJava::J('org.ohdsi.featureExtraction.JarChecksum', 'computeJarChecksum'))"
}

build_branch() {
  local branch="$1"
  local worktree="$2"

  echo "[info] building branch ${branch} in ${worktree}" >&2

  ( cd "${worktree}" && mvn -q clean package )

  local jar_path
  jar_path=$(cd "${worktree}" && ls inst/java/featureExtraction-*.jar | sort | head -n 1)
  if [[ -z "${jar_path}" ]]; then
    echo "[error] base featureExtraction jar not found for ${branch}" >&2
    exit 1
  fi

  local checksum
  checksum=$( (cd "${worktree}" && compute_checksum "${jar_path}") )
  printf '%s' "${checksum}" > "${worktree}/inst/csv/jarChecksum.txt"

  ( cd "${worktree}" && R CMD INSTALL . >/dev/null )
}

run_benchmark() {
  local branch="$1"
  local worktree="$2"
  local log_path="$3"

  local benchmark_path="${worktree}/${BENCHMARK_SCRIPT_REL}"
  if [[ ! -f "${benchmark_path}" ]]; then
    echo "[error] benchmark script ${BENCHMARK_SCRIPT_REL} not found in ${worktree}" >&2
    exit 1
  fi

  echo "[info] running benchmark for ${branch}" >&2

  # Capture full log (stdout + stderr) for later inspection.
  ( cd "${worktree}" && /usr/bin/time -v Rscript "${BENCHMARK_SCRIPT_REL}" ) &> "${log_path}"

  local commit
  commit=$(cd "${worktree}" && git rev-parse HEAD)

  local script_elapsed
  script_elapsed=$(grep -E "^Elapsed: " "${log_path}" | tail -n 1 | awk '{print $2}')

  local time_elapsed
  time_elapsed=$(grep -E "Elapsed \(wall clock\) time" "${log_path}" | awk '{print $9}')

  local peak_rss
  peak_rss=$(grep -E "Maximum resident set size" "${log_path}" | awk '{print $6}')

  echo -e "${branch}\t${commit}\t${benchmark_path}\t${script_elapsed}\t${time_elapsed}\t${peak_rss}" >> "${SUMMARY_FILE}"
}

for branch in "${BRANCHES[@]}"; do
  worktree_dir="${ROOT_DIR}"
  if [[ "${branch}" != "main" ]]; then
    safe_branch=${branch//\//-}
    worktree_dir="${WORKTREE_ROOT}/${safe_branch}"
  fi

  ensure_worktree "${branch}" "${worktree_dir}"

  build_branch "${branch}" "${worktree_dir}"

  log_file="${LOG_DIR}/${branch//\//-}.log"
  run_benchmark "${branch}" "${worktree_dir}" "${log_file}"
done

echo "[info] benchmark summary written to ${SUMMARY_FILE}" >&2
