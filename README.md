# Bambu Studio Leak Diagnostic

A PowerShell script that samples Bambu Studio's resource usage every 10 seconds and logs it to a CSV, so you can identify memory, handle, or VRAM leaks that cause system-wide freezes.

## Background

Bambu Studio causes a system-wide ~1 FPS freeze after extended use, accelerated by slicing operations. This script was written to capture exactly what was climbing in the background. After one session ending in a freeze, the data revealed:

- **A slicing memory spike** — private bytes jumped ~2,400 MB in 33 seconds during a large slice, pushing the system into paging
- **A confirmed handle leak** — ~50–65 handles leak per slice and never fully recover, ratcheting up over a session

Full findings with raw data: [BambuStudio issue tracker](https://github.com/bambulab/BambuStudio/issues)

---

## What it logs (every 10 seconds)

| Column | Source | What it reveals |
|---|---|---|
| `WorkingSet_MB` | `Get-Process` | Pages currently in physical RAM |
| `PrivateBytes_MB` | `Get-Process` | Memory only Bambu owns — best leak signal |
| `HandleCount` | `Get-Process` | File/mutex/event handles — handle leak signal |
| `ThreadCount` | `Get-Process` | Runaway thread spawning |
| `VRAM_TotalUsed_MB` | `nvidia-smi` | Total VRAM across all processes |
| `VRAM_Total_MB` | `nvidia-smi` | Your card's ceiling |
| `GPU_Util_Pct` | `nvidia-smi` | GPU load % |
| `VRAM_BambuProcess_MB` | PDH `GPU Process Memory\Dedicated Usage` | Bambu's slice of VRAM specifically |
| `SysRAM_Used_MB` | `Win32_OperatingSystem` | Whole-system RAM pressure |
| `PageFile_Used_MB` | `Win32_PageFileUsage` | If RAM fills, Windows spills here — growth confirms real pressure |

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (built into Windows — no install needed)
- NVIDIA GPU with drivers installed (`nvidia-smi` must be on PATH)
- Bambu Studio running as a normal user process

---

## Usage

1. Download `bambu_diag.ps1`
2. Open PowerShell in the same folder
3. Run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File bambu_diag.ps1
   ```
4. Use Bambu Studio normally — slice things, load models, do whatever triggers the freeze
5. Press `Ctrl+C` to stop, or just let it run until the freeze hits and recover the CSV after reboot
6. Open `bambu_diag.csv` in Excel or any spreadsheet app and look for columns that climb monotonically

The script also prints a **live status line** every 10 seconds and will show a **popup warning** if Bambu's handle count exceeds 1,250 — a sign you should restart Bambu before the next big slice pushes you over the edge.

---

## What to look for in the CSV

| Pattern | Meaning |
|---|---|
| `PrivateBytes_MB` climbing monotonically | Classic heap/memory leak |
| `HandleCount` climbing and not recovering after slices | Handle leak (confirmed in v2.6.1.55) |
| `VRAM_BambuProcess_MB` climbing across slices | GPU resource leak |
| `PageFile_Used_MB` spiking | RAM pressure is real — system is paging |
| Sudden `PrivateBytes_MB` spike of 1,500+ MB | Large slice in progress — freeze risk if system RAM is low |

---

## Tested on

| Component | Spec |
|---|---|
| CPU | Intel i9-9900K |
| RAM | 32 GB |
| GPU | NVIDIA RTX 2080 Ti (11 GB VRAM) |
| OS | Windows 11 Pro 22631 |
| Bambu Studio | 2.6.1.55 |
