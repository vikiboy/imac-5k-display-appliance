#!/bin/zsh
set -euo pipefail

readonly MAX_DURATION_SECONDS=86400
readonly MAX_SAMPLES=10001

usage() {
  cat <<'USAGE'
Usage:
  collect_resources.zsh --ssh-host USER@HOST --duration SECONDS \
    --interval SECONDS --output FILE

Collect a finite resource sample from the installed local TargetBridge sender
and the installed remote 2017-iMac receiver. FILE must not already exist.

Required:
  --ssh-host USER@HOST  Existing key-based SSH target for the iMac. The target
                        is used for the connection but is not written to FILE.
  --duration SECONDS    Requested run length, 1..86400 seconds.
  --interval SECONDS    Sampling interval, 1..duration seconds.
  --output FILE         New TSV output file. Its parent directory must exist.

The installed paths and process names sampled are:
  local:  ~/Applications/TargetBridge 5K Sender.app (TargetBridge)
  remote: ~/Applications/TargetBridge 5K Receiver.app (TargetBridge5KReceiver)

The collector runs in the foreground, never invokes sudo, never reads screen
frames or application log contents, and starts no persistent process.
USAGE
}

fail() {
  print -u2 -r -- "collect_resources: $*"
  exit 2
}

require_unsigned_integer() {
  local label="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*) fail "$label must be an integer" ;;
  esac
}

disk_kib() {
  local target_path="$1"
  local usage
  if [[ ! -e "$target_path" ]]; then
    print -r -- 0
    return
  fi
  usage=$(/usr/bin/du -sk -- "$target_path" 2>/dev/null || true)
  if [[ -n "$usage" ]]; then
    print -r -- "$usage" | /usr/bin/awk 'NR == 1 {print $1}'
  else
    print -r -- na
  fi
}

collect_machine_payload() {
  local process_name="$1"
  local app_path="$2"
  local support_path="$3"
  local log_path="$4"
  local process_status=running pid=na cpu_percent=na rss_kib=na vsz_kib=na
  local thread_count=na open_fd_count=na
  local app_kib support_kib log_kib
  local pid_lines pid_count process_stats expected_command battery_output
  local power_source battery_percent battery_state thermal_state

  expected_command="${app_path}/Contents/MacOS/${process_name}"
  pid_lines=$(/bin/ps -ww -axo pid=,command= 2>/dev/null | /usr/bin/awk \
    -v expected="$expected_command" '
      match($0, /^[[:space:]]*[0-9]+[[:space:]]+/) {
        prefix = substr($0, 1, RLENGTH)
        pid = prefix
        gsub(/[[:space:]]/, "", pid)
        command = substr($0, RLENGTH + 1)
        if (command == expected || index(command, expected " ") == 1) print pid
      }
    ')
  pid_count=$(print -r -- "$pid_lines" |
    /usr/bin/awk 'NF {count++} END {print count + 0}')
  if (( pid_count == 0 )); then
    process_status=missing
  elif (( pid_count > 1 )); then
    process_status=multiple
  else
    pid=$(print -r -- "$pid_lines" | /usr/bin/awk 'NF {print; exit}')
    process_stats=$(
      /bin/ps -p "$pid" -o %cpu= -o rss= -o vsz= 2>/dev/null || true
    )
    if [[ -z "$process_stats" ]]; then
      process_status=vanished
      pid=na
    else
      cpu_percent=$(print -r -- "$process_stats" |
        /usr/bin/awk 'NR == 1 {print $1}')
      rss_kib=$(print -r -- "$process_stats" |
        /usr/bin/awk 'NR == 1 {print $2}')
      vsz_kib=$(print -r -- "$process_stats" |
        /usr/bin/awk 'NR == 1 {print $3}')
      thread_count=$( { /bin/ps -M -p "$pid" 2>/dev/null || true; } |
        /usr/bin/awk 'NR > 1 {count++} END {print count + 0}')
      if (( thread_count == 0 )); then
        process_status=vanished
        pid=na cpu_percent=na rss_kib=na vsz_kib=na thread_count=na
      else
        open_fd_count=$( {
          /usr/sbin/lsof -n -P -a -p "$pid" -F f 2>/dev/null || true
        } | /usr/bin/awk '/^f[0-9]+$/ {count++} END {print count + 0}')
      fi
    fi
  fi

  app_kib=$(disk_kib "$app_path")
  support_kib=$(disk_kib "$support_path")
  log_kib=$(disk_kib "$log_path")

  battery_output=$(/usr/bin/pmset -g batt 2>/dev/null || true)
  power_source=$(print -r -- "$battery_output" |
    /usr/bin/awk -F "'" 'NR == 1 && NF >= 2 {print $2; exit}')
  [[ -n "$power_source" ]] || power_source=unavailable
  battery_percent=$(print -r -- "$battery_output" | /usr/bin/awk '
    NR > 1 && match($0, /[0-9]+%/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  ')
  if [[ -z "$battery_percent" ]]; then
    battery_percent=na
    battery_state=not_present
  else
    battery_state=$(print -r -- "$battery_output" | /usr/bin/awk -F ';' '
      NR > 1 && NF >= 2 {
        value = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    ')
    [[ -n "$battery_state" ]] || battery_state=unavailable
  fi
  thermal_state=$( { /usr/bin/pmset -g therm 2>/dev/null || true; } | /usr/bin/awk '
    NF {
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if (result != "") result = result "; "
      result = result $0
    }
    END {print (result == "" ? "unavailable" : result)}
  ')

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$process_status" "$pid" "$cpu_percent" "$rss_kib" "$vsz_kib" \
    "$thread_count" "$open_fd_count" "$app_kib" "$support_kib" "$log_kib" \
    "$power_source" "$battery_percent" "$battery_state" "$thermal_state"
}

SSH_HOST=''
DURATION_SECONDS=''
INTERVAL_SECONDS=''
OUTPUT_PATH=''

while (( $# > 0 )); do
  case "$1" in
    --ssh-host)
      (( $# >= 2 )) || fail '--ssh-host requires a value'
      SSH_HOST="$2"
      shift 2
      ;;
    --duration)
      (( $# >= 2 )) || fail '--duration requires a value'
      DURATION_SECONDS="$2"
      shift 2
      ;;
    --interval)
      (( $# >= 2 )) || fail '--interval requires a value'
      INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || fail '--output requires a value'
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "$SSH_HOST" ]] || fail '--ssh-host is required'
[[ "$SSH_HOST" != *$'\n'* && "$SSH_HOST" != -* ]] ||
  fail '--ssh-host contains unsupported characters'
[[ -n "$DURATION_SECONDS" ]] || fail '--duration is required'
[[ -n "$INTERVAL_SECONDS" ]] || fail '--interval is required'
[[ -n "$OUTPUT_PATH" ]] || fail '--output is required'
[[ "$OUTPUT_PATH" != *$'\n'* ]] || fail '--output must be a single path'

require_unsigned_integer duration "$DURATION_SECONDS"
require_unsigned_integer interval "$INTERVAL_SECONDS"
(( DURATION_SECONDS >= 1 && DURATION_SECONDS <= MAX_DURATION_SECONDS )) ||
  fail "duration must be between 1 and ${MAX_DURATION_SECONDS} seconds"
(( INTERVAL_SECONDS >= 1 && INTERVAL_SECONDS <= DURATION_SECONDS )) ||
  fail 'interval must be between 1 and duration seconds'

PLANNED_SAMPLES=$(
  /usr/bin/awk -v duration="$DURATION_SECONDS" -v interval="$INTERVAL_SECONDS" \
    'BEGIN {print int((duration + interval - 1) / interval) + 1}'
)
readonly PLANNED_SAMPLES
(( PLANNED_SAMPLES <= MAX_SAMPLES )) ||
  fail "requested cadence exceeds the ${MAX_SAMPLES}-sample safety limit"

OUTPUT_PATH="${OUTPUT_PATH:A}"
readonly OUTPUT_DIR="${OUTPUT_PATH:h}"
[[ -d "$OUTPUT_DIR" ]] || fail "output directory does not exist: $OUTPUT_DIR"
[[ ! -e "$OUTPUT_PATH" ]] || fail "refusing to overwrite: $OUTPUT_PATH"

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h:h:h:h}"
local_revision=unavailable
local_tree_state=unavailable
if /usr/bin/git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  local_revision=$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)
  if [[ -n "$(/usr/bin/git -C "$REPO_ROOT" status --porcelain)" ]]; then
    local_tree_state=dirty
  else
    local_tree_state=clean
  fi
fi

remote_ready=$(/usr/bin/ssh \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o ConnectionAttempts=1 \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=1 \
  -o LogLevel=ERROR \
  -- "$SSH_HOST" /bin/zsh -s <<'REMOTE_PREFLIGHT'
set -euo pipefail
for required_command in /bin/ps /usr/bin/awk /usr/bin/du /usr/bin/pmset \
  /usr/sbin/lsof; do
  [[ -x "$required_command" ]] || exit 3
done
print -r -- TB_RESOURCE_REMOTE_READY
REMOTE_PREFLIGHT
) || fail 'SSH preflight failed; verify key-based access and reconnect once manually'
[[ "$remote_ready" == TB_RESOURCE_REMOTE_READY ]] ||
  fail 'SSH preflight returned unexpected output'

temporary_output=$(/usr/bin/mktemp "${OUTPUT_PATH}.tmp.XXXXXX") ||
  fail 'could not create temporary output'
/bin/chmod 0600 "$temporary_output"
cleanup() {
  if [[ -n "${temporary_output:-}" && -e "$temporary_output" ]]; then
    /bin/unlink "$temporary_output"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

{
  print -r -- '# targetbridge_resource_schema=2'
  print -r -- "# git_revision=${local_revision}"
  print -r -- "# worktree=${local_tree_state}"
  print -r -- "# requested_duration_s=${DURATION_SECONDS}"
  print -r -- "# interval_s=${INTERVAL_SECONDS}"
  print -r -- "# planned_max_samples_per_machine=${PLANNED_SAMPLES}"
  print -r -- '# ssh_target=caller_supplied_not_recorded'
  print -r -- $'timestamp_utc\telapsed_s\tmachine\tprocess_status\tpid\tcpu_percent\trss_kib\tvsz_kib\tthread_count\topen_fd_count\tapp_kib\tapp_support_kib\tlog_kib\tpower_source\tbattery_percent\tbattery_state\tthermal_state'
} >> "$temporary_output"

start_epoch=$(/bin/date +%s)
sample_number=0
while true; do
  now_epoch=$(/bin/date +%s)
  elapsed_seconds=$(( now_epoch - start_epoch ))
  (( elapsed_seconds < 0 )) && elapsed_seconds=0
  (( elapsed_seconds > DURATION_SECONDS )) && elapsed_seconds=$DURATION_SECONDS
  timestamp_utc=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)

  local_payload=$(collect_machine_payload \
    TargetBridge \
    "${HOME}/Applications/TargetBridge 5K Sender.app" \
    "${HOME}/Library/Application Support/TargetBridge" \
    "${HOME}/Library/Application Support/TargetBridge/Logs")
  printf '%s\t%s\tlocal_sender\t%s\n' \
    "$timestamp_utc" "$elapsed_seconds" "$local_payload" >> "$temporary_output"

  if remote_payload=$(/usr/bin/ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ConnectionAttempts=1 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=1 \
    -o LogLevel=ERROR \
    -- "$SSH_HOST" /bin/zsh -s <<'REMOTE_SAMPLE'
set -euo pipefail

disk_kib() {
  local target_path="$1"
  local usage
  if [[ ! -e "$target_path" ]]; then
    print -r -- 0
    return
  fi
  usage=$(/usr/bin/du -sk -- "$target_path" 2>/dev/null || true)
  if [[ -n "$usage" ]]; then
    print -r -- "$usage" | /usr/bin/awk 'NR == 1 {print $1}'
  else
    print -r -- na
  fi
}

process_name=TargetBridge5KReceiver
app_path="${HOME}/Applications/TargetBridge 5K Receiver.app"
support_path="${HOME}/Library/Application Support/TargetBridge Receiver"
log_path="${support_path}/Logs"
process_status=running pid=na cpu_percent=na rss_kib=na vsz_kib=na thread_count=na open_fd_count=na

expected_command="${app_path}/Contents/MacOS/${process_name}"
pid_lines=$(/bin/ps -ww -axo pid=,command= 2>/dev/null | /usr/bin/awk \
  -v expected="$expected_command" '
    match($0, /^[[:space:]]*[0-9]+[[:space:]]+/) {
      prefix = substr($0, 1, RLENGTH)
      pid = prefix
      gsub(/[[:space:]]/, "", pid)
      command = substr($0, RLENGTH + 1)
      if (command == expected || index(command, expected " ") == 1) print pid
    }
  ')
pid_count=$(print -r -- "$pid_lines" |
  /usr/bin/awk 'NF {count++} END {print count + 0}')
if (( pid_count == 0 )); then
  process_status=missing
elif (( pid_count > 1 )); then
  process_status=multiple
else
  pid=$(print -r -- "$pid_lines" | /usr/bin/awk 'NF {print; exit}')
  process_stats=$(
    /bin/ps -p "$pid" -o %cpu= -o rss= -o vsz= 2>/dev/null || true
  )
  if [[ -z "$process_stats" ]]; then
    process_status=vanished
    pid=na
  else
    cpu_percent=$(print -r -- "$process_stats" |
      /usr/bin/awk 'NR == 1 {print $1}')
    rss_kib=$(print -r -- "$process_stats" |
      /usr/bin/awk 'NR == 1 {print $2}')
    vsz_kib=$(print -r -- "$process_stats" |
      /usr/bin/awk 'NR == 1 {print $3}')
    thread_count=$( { /bin/ps -M -p "$pid" 2>/dev/null || true; } |
      /usr/bin/awk 'NR > 1 {count++} END {print count + 0}')
    if (( thread_count == 0 )); then
      process_status=vanished
      pid=na cpu_percent=na rss_kib=na vsz_kib=na thread_count=na
    else
      open_fd_count=$( {
        /usr/sbin/lsof -n -P -a -p "$pid" -F f 2>/dev/null || true
      } | /usr/bin/awk '/^f[0-9]+$/ {count++} END {print count + 0}')
    fi
  fi
fi

app_kib=$(disk_kib "$app_path")
support_kib=$(disk_kib "$support_path")
log_kib=$(disk_kib "$log_path")
battery_output=$(/usr/bin/pmset -g batt 2>/dev/null || true)
power_source=$(print -r -- "$battery_output" |
  /usr/bin/awk -F "'" 'NR == 1 && NF >= 2 {print $2; exit}')
[[ -n "$power_source" ]] || power_source=unavailable
battery_percent=$(print -r -- "$battery_output" | /usr/bin/awk '
  NR > 1 && match($0, /[0-9]+%/) {
    print substr($0, RSTART, RLENGTH)
    exit
  }
')
if [[ -z "$battery_percent" ]]; then
  battery_percent=na
  battery_state=not_present
else
  battery_state=$(print -r -- "$battery_output" | /usr/bin/awk -F ';' '
    NR > 1 && NF >= 2 {
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ')
  [[ -n "$battery_state" ]] || battery_state=unavailable
fi
thermal_state=$( { /usr/bin/pmset -g therm 2>/dev/null || true; } | /usr/bin/awk '
  NF {
    gsub(/[[:space:]]+/, " ")
    sub(/^ /, "")
    sub(/ $/, "")
    if (result != "") result = result "; "
    result = result $0
  }
  END {print (result == "" ? "unavailable" : result)}
')

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$process_status" "$pid" "$cpu_percent" "$rss_kib" "$vsz_kib" \
  "$thread_count" "$open_fd_count" "$app_kib" "$support_kib" "$log_kib" \
  "$power_source" "$battery_percent" "$battery_state" "$thermal_state"
REMOTE_SAMPLE
  ); then
    remote_field_count=$(print -r -- "$remote_payload" |
      /usr/bin/awk -F '\t' 'NR == 1 {print NF}')
    remote_line_count=$(print -r -- "$remote_payload" |
      /usr/bin/awk 'END {print NR}')
    if [[ "$remote_line_count" == 1 && "$remote_field_count" == 14 ]]; then
      printf '%s\t%s\tremote_receiver\t%s\n' \
        "$timestamp_utc" "$elapsed_seconds" "$remote_payload" >> "$temporary_output"
    else
      printf '%s\t%s\tremote_receiver\tssh_protocol_error\tna\tna\tna\tna\tna\tna\tna\tna\tna\tna\tna\tna\tna\n' \
        "$timestamp_utc" "$elapsed_seconds" >> "$temporary_output"
    fi
  else
    printf '%s\t%s\tremote_receiver\tssh_error\tna\tna\tna\tna\tna\tna\tna\tna\tna\tna\tna\tna\tna\n' \
      "$timestamp_utc" "$elapsed_seconds" >> "$temporary_output"
  fi

  sample_number=$(( sample_number + 1 ))
  (( elapsed_seconds >= DURATION_SECONDS )) && break
  (( sample_number >= PLANNED_SAMPLES )) && break

  next_elapsed=$(( elapsed_seconds + INTERVAL_SECONDS ))
  (( next_elapsed > DURATION_SECONDS )) && next_elapsed=$DURATION_SECONDS
  now_epoch=$(/bin/date +%s)
  sleep_seconds=$(( start_epoch + next_elapsed - now_epoch ))
  (( sleep_seconds > 0 )) && /bin/sleep "$sleep_seconds"
done

/bin/ln "$temporary_output" "$OUTPUT_PATH" ||
  fail "output appeared during collection; refusing to overwrite: $OUTPUT_PATH"
/bin/unlink "$temporary_output"
temporary_output=''
trap - EXIT HUP INT TERM
print -r -- "Resource samples written: $OUTPUT_PATH"
