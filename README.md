# Pop!\_OS Boot Health Check

A safe, single-file tool to **audit and harden your boot setup** on Pop!\_OS (systemd-boot). It helps prevent scary “`(initramfs)`” drops by checking the right things, warning about risky configs, and offering **guided repairs**.

---

## What this script does

**Audits**

* `/etc/fstab` vs **actual** mounted devices (UUID/PARTUUID) for:

  * **Root (`/`)**
  * **ESP (`/boot/efi`)**
  * **Recovery (`/recovery`)**
* `crypttab` (warns if non-empty / stale)
* **ESP**:

  * Mounted? On the correct mountpoint?
  * Filesystem type **vfat (FAT32)** (required for UEFI)
  * Free space (warns if >85%)
* **Kernel boot config**

  * `kernelstub` options (ensures `root=UUID=…` is sane)
  * `systemd-boot` entries (current, old kernel, recovery)
* Installed **kernel images** & **initramfs** files

**Fixes (safely)**

* `--fix`: Refresh boot artifacts if a **root UUID mismatch** is detected

  * Update `kernelstub` `root=UUID=…`
  * Rebuild `initramfs`
  * Reinstall/refresh `systemd-boot` on the ESP
* `--interactive`: **Back up** and repair **`/etc/fstab`** (with your confirmation)

  * Correct **root** token to `UUID=<actual>`
  * Correct **ESP** token to existing **UUID**/**PARTUUID** (respect current token type)
  * Append `umask=0077` to **ESP**/**Recovery** mount options if missing
  * Set **fsck pass** (`dump/pass` column) to **`0`** for ESP/Recovery
  * Then rebuild `initramfs`, refresh kernelstub & bootloader

> 🔐 By design, the script **never edits `/etc/fstab` unless you use `--interactive`**.

---

## Why you might need this

Typical causes of getting dropped into `(initramfs)` on Pop!\_OS:

* Root **UUID** in `fstab` doesn’t match the real partition (drive cloned/replaced/resized)
* Stale `crypttab` entries (e.g., removed encrypted swap)
* ESP not mounted / wrong token (UUID vs PARTUUID) / not **vfat**
* Kernel `root=…` arg not aligned with the actual root partition

This script audits all of that and offers safe, targeted remediation.

---

## Requirements

* Pop!\_OS **22.04+** (uses **systemd-boot**)
* Tools: `kernelstub`, `bootctl`, `lsblk`, `blkid`, `awk`, `findmnt`
* **sudo** privileges
  (The script auto-uses `sudo blkid` when run unprivileged so you’ll still get correct UUIDs.)

---

## Install

Download the script and make it executable:

```bash
wget -O boot_health_check.sh https://raw.githubusercontent.com/shreyasren/popos-boot-health-check/main/boot_health_check.sh
chmod +x boot_health_check.sh
```

(Or clone this repo.)

---

## Usage

### 1) Check only (no changes)

```bash
./boot_health_check.sh
```

Prints:

* fstab lines (root/ESP/recovery)
* Actual mounted UUIDs/PARTUUIDs
* crypttab contents (or “empty”)
* kernelstub options
* systemd-boot entries
* ESP free space
* Installed kernels & initramfs images

### 2) Auto-fix boot artifacts (does **not** edit `/etc/fstab`)

```bash
./boot_health_check.sh --fix
```

* If a **root UUID mismatch** is detected:

  * Updates `kernelstub` to `root=UUID=<mounted-root-uuid>`
* Always:

  * Rebuilds all initramfs (`update-initramfs -u -k all`)
  * Refreshes `systemd-boot` on the ESP (`bootctl install`)

> Use this when the **kernel** command line needs correction and you want a quick, safe refresh of boot artifacts.

### 3) Interactive `/etc/fstab` repair (with backup)

```bash
./boot_health_check.sh --interactive
```

What happens:

* Backs up `/etc/fstab` → `/etc/fstab.backup-YYYY-MM-DDTHH-MM-SS`
* Proposes fixes and applies them:

  * **Root**: rewrite first column to `UUID=<actual>`
  * **ESP**: keep **UUID vs PARTUUID** as configured; replace the value if mismatched
  * **ESP/Recovery**: append `umask=0077` to mount options if missing; set fsck pass to `0`
* Rebuild initramfs, refresh kernelstub & systemd-boot

---

## Examples

Check only:

```bash
./boot_health_check.sh
```

Auto-fix kernel args/initramfs/bootloader:

```bash
./boot_health_check.sh --fix
```

Interactive fstab repair:

```bash
./boot_health_check.sh --interactive
```

Run under sudo (optional; not required):

```bash
sudo ./boot_health_check.sh
```

---

## Output reference

* **WARNING: Root UUID mismatch**
  Your `/etc/fstab` root entry doesn’t match the actual mounted root.

  * Use `--interactive` to fix fstab, or
  * Use `--fix` to update kernelstub/initramfs/bootloader (fstab unchanged).

* **WARNING: ESP UUID/PARTUUID mismatch**
  Your ESP spec in fstab doesn’t match the actual ESP. Use `--interactive`.

* **WARNING: /boot/efi is not mounted!**
  Bootloader refresh will not persist. Mount it and re-run.

* **WARNING: /boot/efi is ‘ext4’, expected ‘vfat’**
  UEFI mandates FAT32. Ensure the correct partition is mounted as the ESP.

* **WARNING: /boot/efi missing `umask=0077`**
  Hardening recommendation. `--interactive` can append it safely.

* **ESP usage ≥ 85%**
  Clean old kernels on the ESP to avoid write failures during updates.

---

## Notes & Tips

* Keep 2–3 kernels for easy rollbacks:

  ```bash
  echo 'Pop::Keep-Kernels "3";' | sudo tee /etc/apt/apt.conf.d/20pop-kernel
  ```

* When a new kernel appears, prefer:

  ```bash
  sudo apt full-upgrade
  ```

  Pop!\_OS will keep the **previous kernel** available in the boot menu.

* Ensure ESP has space:

  ```bash
  df -h /boot/efi
  ```

  Try to keep usage **< 85%**.

* Seeing `UUID=?` when not running as root?
  The script automatically calls `sudo blkid` for you, so you’ll get proper IDs (you may be prompted for your password once).

---

## Safety model

* No filesystem writes unless you **explicitly** run `--fix` or `--interactive`.
* `--fix` never edits `/etc/fstab`; it only refreshes boot artifacts and kernel args if needed.
* `--interactive` **backs up** `/etc/fstab` before applying any minimal, targeted changes.
* All changes are printed to the terminal.

---

## Uninstall

Just delete the script:

```bash
rm -f boot_health_check.sh
```

No other files are installed; everything else is your system’s standard tooling.

---

## Contributing

Issues and PRs welcome! If you have a corner case (multi-boot, exotic layouts), open a ticket with:

* `cat /etc/fstab`
* `sudo lsblk -f`
* `sudo kernelstub --print-config`
* `sudo bootctl list`
* `df -h /boot/efi`

---

## License

**MIT** — see [`LICENSE`](LICENSE).
