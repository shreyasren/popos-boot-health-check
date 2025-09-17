#!/usr/bin/env bash
# Pop!_OS Boot Health Check
# Audits & hardens boot config for Pop!_OS (systemd-boot).
# - Checks /etc/fstab against actual mounted UUID/PARTUUID
# - Audits ESP (/boot/efi) mount, FS type (must be FAT32/vfat), and space
# - Warns if crypttab non-empty
# - Shows kernelstub config and systemd-boot entries
# - Lists installed kernels and initramfs images
# Modes:
#   (no arg)        -> checks only
#   --fix           -> refresh kernelstub/initramfs/bootloader if root UUID mismatch
#   --interactive   -> Backup + repair /etc/fstab (root/ESP/recovery), then refresh
#
# Safe-by-default: never edits /etc/fstab unless --interactive is used.

set -euo pipefail

RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; CLR=$'\e[0m'
MODE="${1:-}"   # "", --fix, or --interactive

echo "== Boot Health Check =="
echo "Date: $(date)"
echo

# -------- Helpers --------
norm_id() { sed -E 's/^(UUID=|PARTUUID=)//'; }
fstab_token_type() { case "$1" in UUID=*) echo "UUID";; PARTUUID=*) echo "PARTUUID";; *) echo "RAW";; esac; }
confirm() { read -r -p "$1 [y/N]: " ans; [[ "${ans:-}" =~ ^[Yy]$ ]]; }

parse_fstab() { awk -v mp="$1" '$2==mp{print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6; exit}' /etc/fstab; }
f_spec() { echo "$1" | awk -F'\t' '{print $1}'; }
f_type() { echo "$1" | awk -F'\t' '{print $3}'; }
f_opts() { echo "$1" | awk -F'\t' '{print $4}'; }
f_pass() { echo "$1" | awk -F'\t' '{print $6}'; }

# -------- Parse fstab --------
ROOT_PARSED="$(parse_fstab "/")"
ESP_PARSED="$(parse_fstab "/boot/efi")"
REC_PARSED="$(parse_fstab "/recovery")"

ROOT_SPEC="$(f_spec "$ROOT_PARSED" || true)"
ESP_SPEC="$(f_spec "$ESP_PARSED" || true)"
REC_SPEC="$(f_spec "$REC_PARSED" || true)"

ROOT_TOKEN="$(fstab_token_type "${ROOT_SPEC:-}")"
ESP_TOKEN="$(fstab_token_type "${ESP_SPEC:-}")"

ROOT_ID_FSTAB="$(printf '%s' "${ROOT_SPEC:-}" | norm_id)"
ESP_ID_FSTAB="$(printf '%s' "${ESP_SPEC:-}" | norm_id)"

echo "-- fstab entries --"
echo "root    : ${ROOT_PARSED:-<none>}"
echo "esp     : ${ESP_PARSED:-<none>}"
echo "recovery: ${REC_PARSED:-<none>}"
echo

# -------- Actual devices --------
ROOT_DEV="$(df --output=source / | tail -n1 || true)"
ESP_DEV="$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)"

# auto-sudo blkid if not root
if [[ $EUID -ne 0 ]]; then BLKID="sudo blkid"; else BLKID="blkid"; fi

ROOT_UUID_REAL="$($BLKID -s UUID -o value "${ROOT_DEV:-}" 2>/dev/null || true)"
ESP_UUID_REAL="$($BLKID -s UUID -o value "${ESP_DEV:-}" 2>/dev/null || true)"
ESP_PARTUUID_REAL="$($BLKID -s PARTUUID -o value "${ESP_DEV:-}" 2>/dev/null || true)"

echo "-- actual devices --"
echo "root dev=${ROOT_DEV:-?} UUID=${ROOT_UUID_REAL:-?}"
echo "esp  dev=${ESP_DEV:-?} UUID=${ESP_UUID_REAL:-?} PARTUUID=${ESP_PARTUUID_REAL:-?}"
echo

MISMATCH_ROOT=0; MISMATCH_ESP=0
[[ -n "$ROOT_ID_FSTAB" && -n "$ROOT_UUID_REAL" && "$ROOT_ID_FSTAB" != "$ROOT_UUID_REAL" ]] && { echo "${RED}WARNING:${CLR} Root UUID mismatch"; MISMATCH_ROOT=1; }
if [[ -n "$ESP_PARSED" ]]; then
  if [[ "$ESP_TOKEN" == "UUID" && -n "$ESP_UUID_REAL" && "$ESP_ID_FSTAB" != "$ESP_UUID_REAL" ]]; then
    echo "${RED}WARNING:${CLR} ESP UUID mismatch"; MISMATCH_ESP=1
  elif [[ "$ESP_TOKEN" == "PARTUUID" && -n "$ESP_PARTUUID_REAL" && "$ESP_ID_FSTAB" != "$ESP_PARTUUID_REAL" ]]; then
    echo "${RED}WARNING:${CLR} ESP PARTUUID mismatch"; MISMATCH_ESP=1
  fi
fi
echo

# -------- ESP mount checks --------
if ! mountpoint -q /boot/efi; then
  echo "${RED}WARNING:${CLR} /boot/efi is not mounted! Bootloader updates will fail."
else
  FSTYPE=$(findmnt -no FSTYPE /boot/efi || true)
  [[ "$FSTYPE" != "vfat" ]] && echo "${RED}WARNING:${CLR} ESP is $FSTYPE, expected vfat (FAT32)."
fi
echo

# -------- Audit ESP & Recovery options --------
audit_entry() {
  local line="$1" mp="$2"; [[ -z "$line" ]] && return
  local fstype=$(f_type "$line"); local opts=$(f_opts "$line"); local pass=$(f_pass "$line")
  if [[ "$fstype" == "vfat" ]]; then
    [[ "$opts" != *"umask=0077"* ]] && echo "${RED}WARNING:${CLR} $mp missing umask=0077"
    [[ "$pass" != "0" ]] && echo "${RED}WARNING:${CLR} $mp fsck pass should be 0"
  fi
}
audit_entry "$ESP_PARSED" "/boot/efi"
audit_entry "$REC_PARSED" "/recovery"
echo

# -------- crypttab --------
echo "-- crypttab --"
[[ -s /etc/crypttab ]] && cat /etc/crypttab || echo "(empty)"
echo

# -------- kernelstub / bootctl --------
echo "-- kernelstub --"
sudo kernelstub --print-config || true
echo
echo "-- bootctl --"
sudo bootctl list || true
echo

# -------- ESP free space & kernels --------
echo "-- ESP usage --"
df -h /boot/efi || true
ESP_USE=$(df --output=pcent /boot/efi 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)
(( ESP_USE > 85 )) && echo "${RED}WARNING:${CLR} ESP is ${ESP_USE}% full. Remove old kernels." || echo "ESP usage OK (${ESP_USE}%)."
echo
echo "-- Initramfs images --"
ls -lh /boot/initrd.img* 2>/dev/null || true
echo
echo "-- Installed kernel images --"
dpkg -l | grep '^ii  linux-image-' || true
echo

# -------- --fix: auto refresh if root UUID mismatch --------
if [[ "$MODE" == "--fix" ]]; then
  echo "${YEL}== --fix: correcting kernelstub/initramfs/bootloader if root UUID mismatch ==${CLR}"
  if [[ $MISMATCH_ROOT -eq 1 && -n "$ROOT_UUID_REAL" ]]; then
    echo "Updating kernelstub root=UUID=$ROOT_UUID_REAL ..."
    CURRENT_OPTS="$(sudo kernelstub --print-config 2>/dev/null | awk -F': ' '/Kernel Boot Options/{print $2}' || true)"
    if [[ -n "$CURRENT_OPTS" ]]; then
      CLEAN_OPTS="$(printf '%s\n' "$CURRENT_OPTS" | sed -E 's/[[:space:]]*root=[^[:space:]]+//g')"
      sudo kernelstub --remove-options "$CURRENT_OPTS" >/dev/null 2>&1 || true
      # shellcheck disable=SC2086
      sudo kernelstub --add-options "$CLEAN_OPTS" >/dev/null 2>&1 || true
    fi
    sudo kernelstub --add-options "root=UUID=$ROOT_UUID_REAL"
    echo "${GRN}kernelstub root updated.${CLR}"
  else
    echo "Root UUID matches or cannot resolve; no kernelstub change."
  fi
  echo "Rebuilding initramfs..."
  sudo update-initramfs -u -k all || true
  echo "Refreshing systemd-boot on ESP..."
  sudo bootctl install || true
  echo "${GRN}--fix complete.${CLR}"
  exit 0
fi

# -------- --interactive: repair fstab & then refresh artifacts --------
if [[ "$MODE" == "--interactive" ]]; then
  BACKUP="/etc/fstab.backup-$(date -Is | tr ':' '-')"
  sudo cp /etc/fstab "$BACKUP"
  echo "Backup saved: $BACKUP"

  changed=0
  fix_line_spec() { sudo awk -v tgt="$1" -v repl="$2" '($2==tgt){$1=repl} {print}' /etc/fstab >/tmp/fstab.$$ && sudo mv /tmp/fstab.$$ /etc/fstab; }

  # Fix root UUID mismatch
  if [[ $MISMATCH_ROOT -eq 1 && -n "$ROOT_UUID_REAL" && -n "$ROOT_PARSED" ]]; then
    echo "Fix / spec → UUID=$ROOT_UUID_REAL"
    fix_line_spec "/" "UUID=$ROOT_UUID_REAL"; changed=1
  fi

  # Fix ESP spec mismatch (respect token kind)
  if [[ $MISMATCH_ESP -eq 1 && -n "$ESP_PARSED" ]]; then
    if [[ "$ESP_TOKEN" == "PARTUUID" && -n "$ESP_PARTUUID_REAL" ]]; then
      echo "Fix /boot/efi spec → PARTUUID=$ESP_PARTUUID_REAL"
      fix_line_spec "/boot/efi" "PARTUUID=$ESP_PARTUUID_REAL"; changed=1
    elif [[ -n "$ESP_UUID_REAL" ]]; then
      echo "Fix /boot/efi spec → UUID=$ESP_UUID_REAL"
      fix_line_spec "/boot/efi" "UUID=$ESP_UUID_REAL"; changed=1
    fi
  fi

  # Add umask=0077 and set pass=0 for ESP & recovery (if present and vfat)
  fix_opts_pass() {
    local mp="$1"
    local line; line="$(awk -v mp="$mp" '$2==mp{print}' /etc/fstab)"
    [[ -z "$line" ]] && return
    local fstype=$(echo "$line" | awk '{print $3}')
    local opts=$(echo "$line" | awk '{print $4}')
    local pass=$(echo "$line" | awk '{print $6}')
    [[ "$fstype" != "vfat" ]] && return
    local newopts="$opts"; [[ "$opts" != *"umask=0077"* ]] && newopts="${opts},umask=0077"
    if [[ "$newopts" != "$opts" || "$pass" != "0" ]]; then
      echo "Fix $mp options → $newopts ; fsck pass → 0"
      sudo awk -v mp="$mp" -v no="$newopts" '($2==mp){$4=no;$6=0} {print}' /etc/fstab >/tmp/fstab.$$ && sudo mv /tmp/fstab.$$ /etc/fstab
      changed=1
    fi
  }
  fix_opts_pass "/boot/efi"
  fix_opts_pass "/recovery"

  if [[ $changed -eq 1 ]]; then
    echo "Rebuilding initramfs..."
    sudo update-initramfs -u -k all || true
    echo "Refreshing kernelstub root= to mounted root UUID..."
    if [[ -n "$ROOT_UUID_REAL" ]]; then
      CURRENT_OPTS="$(sudo kernelstub --print-config 2>/dev/null | awk -F': ' '/Kernel Boot Options/{print $2}' || true)"
      if [[ -n "$CURRENT_OPTS" ]]; then
        CLEAN_OPTS="$(printf '%s\n' "$CURRENT_OPTS" | sed -E 's/[[:space:]]*root=[^[:space:]]+//g')"
        sudo kernelstub --remove-options "$CURRENT_OPTS" >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        sudo kernelstub --add-options "$CLEAN_OPTS" >/dev/null 2>&1 || true
      fi
      sudo kernelstub --add-options "root=UUID=$ROOT_UUID_REAL"
    fi
    echo "Refreshing systemd-boot..."
    sudo bootctl install || true
    echo "${GRN}Interactive repair complete.${CLR}"
  else
    echo "No fstab changes needed."
  fi
fi

echo "== Done =="
