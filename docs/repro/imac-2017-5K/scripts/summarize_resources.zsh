#!/bin/zsh
set -euo pipefail

input_path="${1:-}"
warmup_seconds="${2:-0}"
[[ -n "$input_path" && -f "$input_path" ]] || {
  print -u2 "Usage: summarize_resources.zsh RESOURCE_SAMPLES.tsv [WARMUP_SECONDS]"
  exit 2
}
case "$warmup_seconds" in
  ''|*[!0-9]*)
    print -u2 "WARMUP_SECONDS must be a non-negative integer"
    exit 2
    ;;
esac

/usr/bin/awk -F '\t' -v warmup="$warmup_seconds" '
  BEGIN {
    OFS = "\t"
    print "machine", "warmup_excluded_s", "samples", "duration_s", "cpu_mean_pct", "cpu_max_pct", \
          "rss_first_kib", "rss_last_kib", "rss_min_kib", "rss_max_kib", \
          "rss_slope_mib_per_hour", "threads_min", "threads_max", \
          "fds_min", "fds_max", "app_delta_kib", "support_delta_kib", \
          "log_delta_kib", "non_running_samples", "thermal_warning_samples"
  }
  /^#/ || $1 == "timestamp_utc" { next }
  NF < 17 { next }
  ($2 + 0) < warmup { next }
  {
    machine = $3
    elapsed = $2 + 0
    if (!(machine in count)) {
      first_elapsed[machine] = elapsed
      first_rss[machine] = $7 + 0
      min_rss[machine] = $7 + 0
      max_rss[machine] = $7 + 0
      min_threads[machine] = $9 + 0
      max_threads[machine] = $9 + 0
      min_fds[machine] = $10 + 0
      max_fds[machine] = $10 + 0
      first_app[machine] = $11 + 0
      first_support[machine] = $12 + 0
      first_log[machine] = $13 + 0
      order[++machine_count] = machine
    }
    count[machine]++
    last_elapsed[machine] = elapsed
    last_rss[machine] = $7 + 0
    last_app[machine] = $11 + 0
    last_support[machine] = $12 + 0
    last_log[machine] = $13 + 0
    cpu_sum[machine] += $6 + 0
    if (($6 + 0) > cpu_max[machine]) cpu_max[machine] = $6 + 0
    if (($7 + 0) < min_rss[machine]) min_rss[machine] = $7 + 0
    if (($7 + 0) > max_rss[machine]) max_rss[machine] = $7 + 0
    if (($9 + 0) < min_threads[machine]) min_threads[machine] = $9 + 0
    if (($9 + 0) > max_threads[machine]) max_threads[machine] = $9 + 0
    if (($10 + 0) < min_fds[machine]) min_fds[machine] = $10 + 0
    if (($10 + 0) > max_fds[machine]) max_fds[machine] = $10 + 0
    sum_x[machine] += elapsed
    sum_y[machine] += $7 + 0
    sum_xx[machine] += elapsed * elapsed
    sum_xy[machine] += elapsed * ($7 + 0)
    if ($4 != "running") non_running[machine]++
    if (index($17, "No thermal warning level has been recorded") == 0 ||
        index($17, "No performance warning level has been recorded") == 0) {
      thermal_warning[machine]++
    }
  }
  END {
    for (index_number = 1; index_number <= machine_count; index_number++) {
      machine = order[index_number]
      denominator = count[machine] * sum_xx[machine] - \
                    sum_x[machine] * sum_x[machine]
      slope = denominator == 0 ? 0 : \
        (count[machine] * sum_xy[machine] - sum_x[machine] * sum_y[machine]) / \
        denominator
      slope_mib_hour = slope * 3600.0 / 1024.0
      printf "%s\t%d\t%d\t%d\t%.2f\t%.2f\t%d\t%d\t%d\t%d\t%.3f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
        machine, warmup, count[machine], last_elapsed[machine] - first_elapsed[machine], \
        cpu_sum[machine] / count[machine], cpu_max[machine], \
        first_rss[machine], last_rss[machine], min_rss[machine], max_rss[machine], \
        slope_mib_hour, min_threads[machine], max_threads[machine], \
        min_fds[machine], max_fds[machine], \
        last_app[machine] - first_app[machine], \
        last_support[machine] - first_support[machine], \
        last_log[machine] - first_log[machine], \
        non_running[machine] + 0, thermal_warning[machine] + 0
    }
  }
' "$input_path"
