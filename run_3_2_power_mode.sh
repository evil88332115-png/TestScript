#!/usr/bin/env bash
set -u

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  RED=$'\033[1;31m'
  YELLOW=$'\033[1;33m'
  RESET=$'\033[0m'
else
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
fi

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="${HOME}/.3-2_power_mode_state"
STATE_FILE="${STATE_DIR}/state.env"
STATE_RESULT_FILE="${STATE_DIR}/power_mode_result.txt"
LOG_DIR="${HOME}/3-2_power_mode_$(date +%Y%m%d_%H%M%S)"
RESULT_FILE="${LOG_DIR}/power_mode_result.txt"
TRANSCRIPT_FILE=""
AUTO_RESUME="${AUTO_RESUME:-0}"
TRANSCRIPT_STARTED="${TRANSCRIPT_STARTED:-0}"
AUTORUN_SERVICE="run-3-2-power-mode-resume.service"
AUTORUN_DESKTOP="${HOME}/.config/autostart/run-3-2-power-mode-resume.desktop"
AUTORUN_TERMINAL_SCRIPT="${HOME}/.local/bin/run_3_2_power_mode_resume_terminal.sh"
POWER_LIST_CMD="awk -F'[= ]' '/^< POWER_MODEL/{print \$4,\$6}' /etc/nvpmodel.conf"

mkdir -p "${STATE_DIR}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

die() {
  printf '%sERROR: %s%s\n' "${RED}" "$*" "${RESET}"
  exit 1
}

run_sudo() {
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "${SUDO_PASSWORD}" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

run_nvpmodel_decline_reboot() {
  local mode_id="$1"

  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n\n' "${SUDO_PASSWORD}" | sudo -S -p '' nvpmodel -m "${mode_id}"
  else
    printf '\n' | sudo nvpmodel -m "${mode_id}"
  fi
}

run_nvpmodel_confirm_reboot() {
  local mode_id="$1"

  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\nYES\n' "${SUDO_PASSWORD}" | sudo -S -p '' nvpmodel -m "${mode_id}"
  else
    printf 'YES\n' | sudo nvpmodel -m "${mode_id}"
  fi
}

ensure_writable_dir() {
  local path="$1"
  local owner

  [[ -e "${path}" ]] || mkdir -p "${path}"
  [[ -d "${path}" ]] || return 0
  [[ -w "${path}" ]] && return 0

  owner="$(id -u):$(id -g)"
  echo "Directory is not writable by current user: ${path}"
  echo "Trying to fix ownership: sudo chown -R ${owner} ${path}"
  run_sudo chown -R "${owner}" "${path}"

  [[ -w "${path}" ]] || die "Directory is still not writable: ${path}"
}

run_power_list() {
  awk -F'[= ]' '/^< POWER_MODEL/{print $4,$6}' /etc/nvpmodel.conf
}

get_mode_name() {
  local id="$1"
  run_power_list | awk -v id="${id}" '$1 == id {print $2; exit}'
}

get_current_mode_id() {
  nvpmodel -q 2>/dev/null | awk '/^[0-9]+$/ {print $1; exit}'
}

get_current_mode_name() {
  nvpmodel -q 2>/dev/null | awk -F': ' '/NV Power Mode:/ {print $2; exit}'
}

ensure_sudo_auth() {
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    run_sudo -v
    return
  fi

  if sudo -n true 2>/dev/null; then
    return 0
  fi

  echo "sudo authentication is required to read jetson_clocks."
  sudo -v
}

print_freq_info() {
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    run_sudo jetson_clocks --show 2>&1
  else
    sudo -n jetson_clocks --show 2>&1
  fi |
    awk '
      # R36 reports Online=1 on each cpuN line, whereas R39 reports the
      # online set once as "Online CPUs: 0-5, Offline CPUs: ...".  Build the
      # latter set when present so both formats exclude genuinely offline CPUs.
      /^Online CPUs:/ {
        online_list = $0
        sub(/^Online CPUs:[[:space:]]*/, "", online_list)
        sub(/,[[:space:]]*Offline CPUs:.*/, "", online_list)
        gsub(/[[:space:]]/, "", online_list)
        if (online_list != "") {
          online_list_available = 1
          count = split(online_list, ranges, ",")
          for (r = 1; r <= count; r++) {
            if (ranges[r] ~ /^[0-9]+-[0-9]+$/) {
              split(ranges[r], bounds, "-")
              for (cpu_id = bounds[1]; cpu_id <= bounds[2]; cpu_id++) {
                online_cpu[cpu_id] = 1
              }
            } else if (ranges[r] ~ /^[0-9]+$/) {
              online_cpu[ranges[r]] = 1
            }
          }
        }
        next
      }
      /^cpu[0-9]+:/ {
        cpu_name = $1
        sub(/:$/, "", cpu_name)
        cpu_id = cpu_name
        sub(/^cpu/, "", cpu_id)
        online = -1
        for (i = 1; i <= NF; i++) {
          if ($i == "Online=1") online = 1
          else if ($i == "Online=0") online = 0
        }
        if (online_list_available) online = (cpu_id in online_cpu)
        # Keep compatibility with formats that expose neither online marker.
        if (online != 0) {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^MaxFreq=/) print $1, $i
          }
        }
        next
      }
      /^GPU |^EMC / {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^MaxFreq=/) print $1, $i
        }
      }
    '
}

read_model() {
  local model_file
  for model_file in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    if [[ -r "${model_file}" ]]; then
      tr -d '\0' < "${model_file}"
      return
    fi
  done
  echo "unknown"
}

check_orin_series() {
  local model
  model="$(read_model)"

  echo "Supported platform: Jetson Orin series only"
  echo "Detected platform: ${model}"

  if [[ "${model,,}" != *"orin"* ]]; then
    die "Unsupported platform. This script supports Jetson Orin series only."
  fi
}

read_module_short() {
  local model model_lower mem_raw_gib mem_gib module
  model="$(read_model)"
  model_lower="${model,,}"
  mem_raw_gib="$(awk '/MemTotal/ {printf "%.2f", $2/1024/1024}' /proc/meminfo 2>/dev/null)"
  mem_gib="$(awk -v m="${mem_raw_gib:-0}" 'BEGIN {
    if (m <= 0) print "";
    else if (m <= 2.5) print "2";
    else if (m <= 4.8) print "4";
    else if (m <= 9.5) print "8";
    else if (m <= 18) print "16";
    else if (m <= 36) print "32";
    else if (m <= 72) print "64";
    else printf "%.0f", m;
  }')"

  case "${model_lower}" in
    *"jetson orin nano"*|*"orin nano"*) module="orin nano" ;;
    *"jetson orin nx"*|*"orin nx"*) module="orin nx" ;;
    *"jetson agx orin"*|*"agx orin"*) module="agx orin" ;;
    *"jetson"*"orin"*) module="${model}" ;;
    *) module="${model}" ;;
  esac

  if [[ -n "${mem_gib}" && "${mem_gib}" != "0" ]]; then
    echo "${module} ${mem_gib}G"
  else
    echo "${module}"
  fi
}

detect_power_config() {
  local cfg_real cfg_base cfg_lower text_line inferred
  cfg_real="$(readlink -f /etc/nvpmodel.conf 2>/dev/null || echo /etc/nvpmodel.conf)"
  cfg_base="$(basename "${cfg_real}")"
  cfg_lower="${cfg_base,,}"
  text_line="$(grep -im1 -E 'super|normal|nvpmodel|p3767|p3768|orin|nano|nx' /etc/nvpmodel.conf 2>/dev/null || true)"

  inferred="unknown config"
  if [[ "${cfg_lower}" == *super*.conf ]]; then
    inferred="super config"
  elif [[ "${cfg_lower}" == nvpmodel_p*.conf ]]; then
    inferred="normal config"
  elif echo "${cfg_base} ${text_line}" | grep -qi 'super'; then
    inferred="super config"
  elif echo "${cfg_base} ${text_line}" | grep -qi 'normal'; then
    inferred="normal config"
  fi

  echo "${inferred}"
  echo "Config file: ${cfg_real}"
  if [[ -n "${text_line}" ]]; then
    echo "Config hint: ${text_line}"
  fi
}

show_header() {
  local module config_info config_line
  module="$(read_module_short)"
  config_info="$(detect_power_config)"
  config_line="$(printf '%s\n' "${config_info}" | head -n 1)"

  echo "======================================"
  echo "3-2 Power Mode"
  echo "Host: $(hostname)"
  echo "Date: $(date --iso-8601=seconds)"
  echo "Module: ${module}"
  echo "Power config: ${config_line}"
  printf '%s\n' "${config_info}" | tail -n +2
  echo "Log directory: ${LOG_DIR}"
  echo "======================================"
}

append_current_mode_record() {
  local requested_id="$1"
  local requested_name="$2"
  local stage="$3"
  local current_id current_name

  ensure_sudo_auth || return 1

  current_id="$(get_current_mode_id || true)"
  current_name="$(get_current_mode_name || true)"

  {
    echo
    echo "===== Power Mode: ${requested_id} ${requested_name} ====="
    echo
    echo "nvpmodel -q"
    nvpmodel -q 2>&1 || true
    echo
    print_freq_info
  } >> "${RESULT_FILE}"

  if [[ "${current_id}" == "${requested_id}" ]]; then
    return 0
  fi
  return 1
}

save_state() {
  local next_index="$1"
  local ids_joined="$2"
  local log_dir="$3"

  cat > "${STATE_FILE}" <<EOF
NEXT_INDEX='${next_index}'
IDS_JOINED='${ids_joined}'
LOG_DIR_SAVED='${log_dir}'
EOF
}

clear_state() {
  rm -f "${STATE_FILE}"
}

start_transcript_log() {
  if [[ "${TRANSCRIPT_STARTED}" == "1" ]]; then
    return
  fi

  TRANSCRIPT_FILE="${LOG_DIR}/3-2_power_mode_full.log"
  touch "${TRANSCRIPT_FILE}"
  export TRANSCRIPT_STARTED=1
  exec > >(tee -a "${TRANSCRIPT_FILE}") 2>&1

  echo
  echo "===== 3-2 transcript started: $(date --iso-8601=seconds) ====="
  echo "Transcript log: ${TRANSCRIPT_FILE}"
  if [[ "${AUTO_RESUME}" == "1" ]]; then
    echo "Resume source: auto-resume after reboot"
  else
    echo "Resume source: manual run before reboot"
  fi
}

install_autoresume_service() {
  local workdir home_dir user_name service_path service_tmp

  workdir="$(pwd)"
  home_dir="${HOME}"
  user_name="$(id -un)"
  service_path="/etc/systemd/system/${AUTORUN_SERVICE}"
  service_tmp="$(mktemp)"

  rm -f "${AUTORUN_DESKTOP}" "${AUTORUN_TERMINAL_SCRIPT}" 2>/dev/null || true
  run_sudo systemctl disable "${AUTORUN_SERVICE}" >/dev/null 2>&1 || true
  run_sudo rm -f "${service_path}" 2>/dev/null || true
  run_sudo systemctl daemon-reload >/dev/null 2>&1 || true

  echo "Enable headless auto-resume after reboot: ${service_path}"
  cat > "${service_tmp}" <<EOF
[Unit]
Description=Resume 3-2 Power Mode Test after reboot
After=multi-user.target

[Service]
Type=oneshot
User=root
Environment=HOME=${home_dir}
Environment=USER=${user_name}
WorkingDirectory=${workdir}
ExecStart=/bin/bash -lc 'export AUTO_RESUME=1 HOME=${home_dir} USER=${user_name}; cd "${workdir}" && ./${SCRIPT_NAME}'
StandardOutput=append:${LOG_DIR}/3-2_power_mode_systemd_resume.log
StandardError=append:${LOG_DIR}/3-2_power_mode_systemd_resume.log

[Install]
WantedBy=multi-user.target
EOF

  run_sudo cp "${service_tmp}" "${service_path}"
  rm -f "${service_tmp}"
  run_sudo systemctl daemon-reload
  run_sudo systemctl enable "${AUTORUN_SERVICE}"
}

disable_autoresume_service() {
  rm -f "${AUTORUN_DESKTOP}" "${AUTORUN_TERMINAL_SCRIPT}" 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    run_sudo systemctl disable "${AUTORUN_SERVICE}" >/dev/null 2>&1 || true
    run_sudo rm -f "/etc/systemd/system/${AUTORUN_SERVICE}" 2>/dev/null || true
    run_sudo systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

fix_output_ownership_if_root() {
  local user_name

  if [[ "$(id -u)" -ne 0 ]]; then
    return
  fi

  user_name="${USER:-}"
  if [[ -z "${user_name}" || "${user_name}" == "root" ]]; then
    return
  fi

  if id "${user_name}" >/dev/null 2>&1; then
    chown -R "${user_name}:${user_name}" "${STATE_DIR}" "${LOG_DIR}" "${HOME}/3-2_power_mode_autoresume.log" 2>/dev/null || true
  fi
}

mode_recorded() {
  local id="$1"
  [[ -s "${RESULT_FILE}" ]] || return 1
  awk -v id="${id}" '
    function complete() {
      return in_target && saw_cpu && saw_gpu && saw_emc
    }
    /^===== Power Mode: / {
      if (complete()) {
        found = 1
      }
      in_target = ($0 ~ "^===== Power Mode: " id " ")
      saw_cpu = 0
      saw_gpu = 0
      saw_emc = 0
      next
    }
    in_target && /^cpu[0-9]+: MaxFreq=/ { saw_cpu = 1 }
    in_target && /^GPU MaxFreq=/ { saw_gpu = 1 }
    in_target && /^EMC MaxFreq=/ { saw_emc = 1 }
    END {
      if (complete()) {
        found = 1
      }
      exit found ? 0 : 1
    }
  ' "${RESULT_FILE}"
}

show_record_progress() {
  local id name completed total
  completed=0
  total="${#MODE_IDS[@]}"

  echo
  echo "Power mode record status:"
  for id in "${MODE_IDS[@]}"; do
    name="$(get_mode_name "${id}")"
    if mode_recorded "${id}"; then
      completed=$((completed + 1))
      printf '  [%sDONE%s] %s %s\n' "${GREEN}" "${RESET}" "${id}" "${name}"
    else
      printf '  [%sTODO%s] %s %s\n' "${YELLOW}" "${RESET}" "${id}" "${name}"
    fi
  done
  echo "Recorded modes: ${completed}/${total}"
  echo "Progress log: ${RESULT_FILE}"
}

first_unrecorded_index() {
  local i id
  for ((i=0; i<${#MODE_IDS[@]}; i++)); do
    id="${MODE_IDS[$i]}"
    if ! mode_recorded "${id}"; then
      echo "${i}"
      return
    fi
  done
  echo "${#MODE_IDS[@]}"
}

load_or_init_state() {
  local ids_joined old_result
  mapfile -t MODE_IDS < <(run_power_list | awk '{print $1}')
  [[ "${#MODE_IDS[@]}" -gt 0 ]] || die "No POWER_MODEL entries found in /etc/nvpmodel.conf"
  ids_joined="${MODE_IDS[*]}"
  ensure_writable_dir "${STATE_DIR}"

  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    LOG_DIR="${LOG_DIR_SAVED:-${LOG_DIR}}"
    ensure_writable_dir "${LOG_DIR}"
    RESULT_FILE="${LOG_DIR}/power_mode_result.txt"
    old_result="${STATE_RESULT_FILE}"
    if [[ ! -s "${RESULT_FILE}" && -s "${old_result}" ]]; then
      cp "${old_result}" "${RESULT_FILE}"
    fi
    echo "Found previous 3-2 power mode test state."
    echo "Log directory: ${LOG_DIR}"
    NEXT_INDEX="$(first_unrecorded_index)"
  else
    NEXT_INDEX=0
    ensure_writable_dir "${LOG_DIR}"
    RESULT_FILE="${LOG_DIR}/power_mode_result.txt"
    rm -f "${RESULT_FILE}"
  fi

  save_state "${NEXT_INDEX}" "${ids_joined}" "${LOG_DIR}"
}

write_initial_report() {
  local module config_info
  module="$(read_module_short)"
  config_info="$(detect_power_config)"

  {
    echo "${module} $(printf '%s\n' "${config_info}" | head -n 1)"
    printf '%s\n' "${config_info}" | tail -n +2
    echo
    echo "List All Power mode"
    echo "$ ${POWER_LIST_CMD}"
    run_power_list
  } > "${RESULT_FILE}"
}

try_switch_mode_without_reboot() {
  local mode_id="$1"
  local mode_name="$2"
  local rc log_file output_file

  echo
  echo "======================================"
  echo "Try Power Mode without reboot confirmation: ${mode_id} ${mode_name}"
  echo "Command: sudo nvpmodel -m ${mode_id}"
  echo "======================================"

  log_file="${LOG_DIR}/nvpmodel_switch_${mode_id}.log"
  output_file="${LOG_DIR}/nvpmodel_switch_${mode_id}.last"
  : > "${output_file}"

  run_nvpmodel_decline_reboot "${mode_id}" 2>&1 | tee -a "${log_file}" | tee "${output_file}"
  rc=${PIPESTATUS[1]}

  if grep -qi 'reboot required\|restart required\|DO YOU WANT TO REBOOT' "${output_file}"; then
    echo "Mode ${mode_id} ${mode_name} requires reboot. It will be handled after non-reboot modes are recorded."
    return 2
  fi

  if [[ "${rc}" -ne 0 ]]; then
    return "${rc}"
  fi

  return 0
}

switch_mode_with_reboot() {
  local mode_id="$1"
  local mode_name="$2"
  local rc log_file

  echo
  echo "======================================"
  echo "Switch Power Mode with reboot: ${mode_id} ${mode_name}"
  echo "Command: printf 'YES\\n' | sudo nvpmodel -m ${mode_id}"
  echo "======================================"

  log_file="${LOG_DIR}/nvpmodel_switch_${mode_id}_reboot.log"
  if [[ "${AUTO_RESUME}" == "1" ]]; then
    echo "Auto-resume mode: switching now. If reboot is required, nvpmodel will reboot automatically."
  else
    echo "Progress is already saved."
    echo "All currently switchable non-reboot modes have already been recorded."
    echo "The script will send YES to nvpmodel automatically."
    echo "After reboot, this script will auto-run once and continue recording."
    echo "Reboot switch will start in 5 seconds. Press Ctrl+C to cancel."
    for sec in 5 4 3 2 1; do
      printf '  %s...\n' "${sec}"
      sleep 1
    done
    install_autoresume_service
  fi

  run_nvpmodel_confirm_reboot "${mode_id}" 2>&1 | tee -a "${log_file}"
  rc=${PIPESTATUS[1]}

  if [[ "${rc}" -ne 0 ]]; then
    return "${rc}"
  fi

  return 0
}

print_final_report() {
  local final_report
  final_report="${LOG_DIR}/3-2_power_mode_summary.txt"
  cp "${RESULT_FILE}" "${final_report}"

  echo
  echo "======================================"
  echo "3-2 Power Mode Summary"
  echo "======================================"
  cat "${final_report}"
  echo
  disable_autoresume_service
  fix_output_ownership_if_root
  printf '%sRESULT,POWER_MODE,PASS,log=%s%s\n' "${GREEN}" "${final_report}" "${RESET}"
}

main() {
  local i mode_id mode_name switch_rc next_i pending_reboot_ids progress_made all_done first_pending

  need_cmd awk || die "awk not found"
  need_cmd sudo || die "sudo not found"
  need_cmd nvpmodel || die "nvpmodel not found"
  need_cmd jetson_clocks || die "jetson_clocks not found"

  load_or_init_state
  start_transcript_log
  check_orin_series
  show_header

  if [[ ! -s "${RESULT_FILE}" ]]; then
    write_initial_report
    NEXT_INDEX="$(first_unrecorded_index)"
    save_state "${NEXT_INDEX}" "${MODE_IDS[*]}" "${LOG_DIR}"
  fi

  show_record_progress

  echo
  echo "Power modes:"
  run_power_list
  echo
  echo "Current mode:"
  nvpmodel -q || true

  while :; do
    pending_reboot_ids=()
    progress_made=0
    all_done=1

    for ((i=0; i<${#MODE_IDS[@]}; i++)); do
      mode_id="${MODE_IDS[$i]}"
      mode_name="$(get_mode_name "${mode_id}")"
      [[ -n "${mode_name}" ]] || mode_name="unknown"

      if mode_recorded "${mode_id}"; then
        continue
      fi

      all_done=0
      save_state "${i}" "${MODE_IDS[*]}" "${LOG_DIR}"

      if [[ "$(get_current_mode_id || true)" == "${mode_id}" ]]; then
        if append_current_mode_record "${mode_id}" "${mode_name}" "recorded-current-or-after-reboot"; then
          if ! mode_recorded "${mode_id}"; then
            printf '%sRESULT,POWER_MODE,%s_%s,FAIL,incomplete-frequency-record%s\n' "${RED}" "${mode_id}" "${mode_name}" "${RESET}"
            die "Power mode changed, but CPU/GPU/EMC frequency data was incomplete. Refusing to repeat indefinitely."
          fi
          progress_made=1
          printf '%sRESULT,POWER_MODE,%s_%s,PASS%s\n' "${GREEN}" "${mode_id}" "${mode_name}" "${RESET}"
          save_state "$(first_unrecorded_index)" "${MODE_IDS[*]}" "${LOG_DIR}"
          continue
        fi
      fi

      try_switch_mode_without_reboot "${mode_id}" "${mode_name}"
      switch_rc=$?

      if [[ "${switch_rc}" -eq 2 ]]; then
        pending_reboot_ids+=("${mode_id}")
        continue
      elif [[ "${switch_rc}" -ne 0 ]]; then
        printf '%sRESULT,POWER_MODE,%s_%s,FAIL,switch_rc=%s%s\n' "${RED}" "${mode_id}" "${mode_name}" "${switch_rc}" "${RESET}"
        exit "${switch_rc}"
      fi

      if append_current_mode_record "${mode_id}" "${mode_name}" "recorded-after-switch"; then
        if ! mode_recorded "${mode_id}"; then
          printf '%sRESULT,POWER_MODE,%s_%s,FAIL,incomplete-frequency-record%s\n' "${RED}" "${mode_id}" "${mode_name}" "${RESET}"
          die "Power mode changed, but CPU/GPU/EMC frequency data was incomplete. Refusing to repeat indefinitely."
        fi
        progress_made=1
        printf '%sRESULT,POWER_MODE,%s_%s,PASS%s\n' "${GREEN}" "${mode_id}" "${mode_name}" "${RESET}"
        save_state "$(first_unrecorded_index)" "${MODE_IDS[*]}" "${LOG_DIR}"
      else
        printf '%sRESULT,POWER_MODE,%s_%s,FAIL,current-mode-mismatch%s\n' "${RED}" "${mode_id}" "${mode_name}" "${RESET}"
        exit 1
      fi
    done

    show_record_progress

    if [[ "$(first_unrecorded_index)" -ge "${#MODE_IDS[@]}" ]]; then
      break
    fi

    if [[ "${#pending_reboot_ids[@]}" -gt 0 && "${progress_made}" -eq 0 ]]; then
      first_pending="${pending_reboot_ids[0]}"
      mode_name="$(get_mode_name "${first_pending}")"
      save_state "$(first_unrecorded_index)" "${MODE_IDS[*]}" "${LOG_DIR}"
      switch_mode_with_reboot "${first_pending}" "${mode_name}"
      switch_rc=$?
      if [[ "${switch_rc}" -ne 0 ]]; then
        printf '%sRESULT,POWER_MODE,%s_%s,FAIL,reboot_switch_rc=%s%s\n' "${RED}" "${first_pending}" "${mode_name}" "${switch_rc}" "${RESET}"
        exit "${switch_rc}"
      fi
      echo "If the system did not reboot, run this script again to continue."
      exit 0
    fi

    if [[ "${progress_made}" -eq 0 ]]; then
      die "No progress was made and no reboot candidate was found."
    fi
  done

  clear_state
  print_final_report
}

main "$@"
