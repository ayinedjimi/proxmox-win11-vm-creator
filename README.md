![Platform](https://img.shields.io/badge/Platform-Proxmox%20VE%208%2F9-E57000?style=for-the-badge&logo=proxmox&logoColor=white)
![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Windows](https://img.shields.io/badge/Guest-Windows%2011%2025H2-0078D6?style=for-the-badge&logo=windows&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

# Proxmox Win11 VM Creator

**One-shot bash script to create a fully working Windows 11 VM on Proxmox VE 9 — including environments where OVMF (UEFI) is broken (nested Hyper-V, some KVM-on-KVM setups, etc.).**

[![Repo Size](https://img.shields.io/github/repo-size/ayinedjimi/proxmox-win11-vm-creator?style=flat-square&color=555)](https://github.com/ayinedjimi/proxmox-win11-vm-creator)

---

## Why this script ?

The official Proxmox best-practices guide for Windows 11 recommends **OVMF (UEFI) + EFI Disk + TPM 2.0**. This is correct on bare metal — but in **nested virtualization** (Proxmox running inside Hyper-V on Windows 11) the OVMF firmware **times out** when trying to read the Windows 11 ISO over emulated SATA/AHCI, leaving the user staring at a black screen with the TianoCore/Proxmox logo.

This script uses the **validated workaround** :

| Choice | Why |
|:-------|:----|
| `bios: seabios` | SeaBIOS uses IDE PIO instead of AHCI MMIO — far less sensitive to nested VM-exit latency |
| no `efidisk0` | Useless without OVMF, would just waste space |
| no `tpmstate0` | Useless without OVMF, the install bypass happens at the Windows side |
| `machine: q35` | Modern PCIe topology, kept like the official procedure |
| All performance options | `iothread`, `discard`, `ssd=1`, `cache=writeback`, `virtio-scsi-single`, `virtio` net |

The TPM / Secure Boot / RAM checks are bypassed at install time with **3 `reg add` commands** (see [usage](#usage-bypass-windows-11-checks-at-install)).

---

## Quick start

### 1. Download on a Proxmox node

```bash
wget -O create-win11-vm.sh https://raw.githubusercontent.com/ayinedjimi/proxmox-win11-vm-creator/main/create-win11-vm.sh
chmod +x create-win11-vm.sh
```

### 2. Run with defaults

```bash
./create-win11-vm.sh
```

This creates VM `200` named `windows11`, 4 cores, 4 GB RAM, 64 GB disk on `local-lvm`, ISO `Win11_25H2_French_x64_v2.iso`.

### 3. Or customize via environment variables

```bash
VMID=205 NAME=poste-formation ./create-win11-vm.sh

# Tout customiser
VMID=210 \
NAME=win11-prod \
WIN_ISO=Win11_25H2_French_x64_v2.iso \
DISK_STORAGE=ceph-vm \
DISK_SIZE=128 \
CORES=8 \
MEMORY=8192 \
BRIDGE=vmbr0 \
./create-win11-vm.sh
```

---

## Configuration

| Variable | Default | Description |
|:---------|:--------|:------------|
| `VMID` | `200` | VM ID (script checks it's free) |
| `NAME` | `windows11` | Display name |
| `WIN_ISO` | `Win11_25H2_French_x64_v2.iso` | Windows 11 ISO filename |
| `VIRTIO_ISO` | *auto* | Auto-detected (searches for `virtio-win*.iso`) |
| `ISO_STORAGE` | `local` | Storage holding the ISOs |
| `DISK_STORAGE` | `local-lvm` | Storage for the VM disk |
| `DISK_SIZE` | `64` | Disk size in GB |
| `CORES` | `4` | vCPU cores |
| `SOCKETS` | `1` | vCPU sockets |
| `CPU_TYPE` | `host` | CPU type (use `x86-64-v2-AES` for migration between heterogeneous CPUs) |
| `MEMORY` | `4096` | RAM in MB |
| `BRIDGE` | `vmbr0` | Network bridge |

---

## Prerequisites

- A working Proxmox VE 9 node (or 8.x — should work)
- The Windows 11 ISO and the VirtIO drivers ISO **uploaded to the node's `local` storage**:
  - `Win11_25H2_French_x64_v2.iso` (or any Windows 11 ISO — pass it via `WIN_ISO=`)
  - `virtio-win.iso` (latest) — get it from [Fedora People](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)

The script auto-detects the exact VirtIO ISO filename (e.g. `virtio-win-0.1.285.iso`).

> ⚠ Storage `local` is **not shared** between cluster nodes. The ISOs must be on the **same node** where you create the VM. Use `nfs-shared` (or any shared storage with `content=iso`) for cluster-wide ISO availability.

---

## Usage — Bypass Windows 11 checks at install

When the Windows 11 installer says **"This PC can't run Windows 11"**:

1. In the Proxmox console, click inside, then press **Shift + F10** → a `cmd.exe` opens
2. Paste these three commands:

```cmd
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f
```

3. Close the cmd, click **Back** then **Next** in the wizard → the error disappears

### At the disk selection screen

The list is empty (Windows doesn't see the VirtIO SCSI disk yet):

1. **Load driver → Browse**
2. Navigate to the VirtIO CD → `vioscsi/w11/amd64`
3. Select **Red Hat VirtIO SCSI pass-through controller** → Next
4. The 64 GB disk appears → select it → Next

> 💡 Tip: also load the network driver now (`NetKVM/w11/amd64` → Red Hat VirtIO Ethernet Adapter) — it saves you from the OOBE Microsoft account prompt later.

### OOBE — Microsoft account bypass (Win11 24H2/25H2)

In the Out-Of-Box-Experience, if Windows forces an online account:

**Method 1 — easiest**: disconnect the virtual NIC **before** OOBE:
```bash
qm set 200 --net0 virtio,bridge=vmbr0,firewall=1,link_down=1
```

**Method 2 — from the OOBE itself**: `Shift+F10` → type `OOBE\BYPASSNRO` → reboot → "I don't have Internet" appears.

**Method 3**: at the network screen, **Alt + F4** sometimes works.

After OOBE, reconnect the NIC if you used method 1:
```bash
qm set 200 --net0 virtio,bridge=vmbr0,firewall=1
```

---

## Post-install steps

Once Windows is on the desktop:

1. Open Explorer → CD drive `virtio-win` (usually D: or E:)
2. Double-click **`virtio-win-gt-x64.msi`** → install with defaults
3. Reboot the VM

The MSI installs all remaining VirtIO drivers (balloon, serial, RNG, …) **and the QEMU Guest Agent** as a Windows service.

### Cleanup the CD drives

```bash
qm set 200 --ide0 none,media=cdrom
qm set 200 --ide1 none,media=cdrom
qm set 200 --boot 'order=scsi0;net0'
```

Or via GUI: VM → Hardware → ide0/ide1 → Edit → **Do not use any media**.

---

## What the script does

1. Verifies root privileges + Proxmox node (qm / pvesm available)
2. Checks the target VMID is free
3. Auto-detects the VirtIO ISO on the storage
4. Verifies the Windows 11 ISO is present
5. Runs `qm create` with the validated config (SeaBIOS, virtio-scsi-single, q35, etc.)
6. Starts the VM
7. Prints the URL to the Proxmox console

You then handle the install interactively as described above.

---

## Tested with

| Component | Version |
|:----------|:--------|
| Proxmox VE | 9.1.6 (Debian Trixie) |
| QEMU | 10.1.2 |
| Windows 11 | 25H2 French x64 (build 26200) |
| VirtIO drivers | 0.1.285 |
| Host | Windows 11 + Hyper-V (AMD EPYC) |
| L1 hypervisor | Hyper-V |
| L2 hypervisor | KVM (inside Proxmox VM) |
| L3 guest | Windows 11 (with this script) |

---

## Related projects

- [**proxmox-cluster-manager**](https://github.com/ayinedjimi/proxmox-cluster-manager) — Web-based monitoring & management dashboard for Proxmox VE clusters
- Articles on [ayinedjimi-consultants.fr](https://www.ayinedjimi-consultants.fr) :
  - [Proxmox VE 9 — Guide complet](https://ayinedjimi-consultants.fr/virtualisation/proxmox-ve-guide-complet.html)
  - [Optimisation Proxmox VE 9.0](https://www.ayinedjimi-consultants.fr/virtualisation/optimisation-proxmox.html)
  - [Migration VMware vers Proxmox 9](https://www.ayinedjimi-consultants.fr/virtualisation/migration-vmware-proxmox.html)

---

## License

MIT License — Copyright (c) 2026 [Ayi NEDJIMI Consultants](https://www.ayinedjimi-consultants.fr)

See [LICENSE](LICENSE) for details.

---

<p align="center">
  <b>Ayi NEDJIMI Consultants</b> — Infrastructure &amp; Virtualization<br>
  <a href="https://www.ayinedjimi-consultants.fr">www.ayinedjimi-consultants.fr</a>
</p>
