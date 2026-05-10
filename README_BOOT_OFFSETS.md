# Boot Sector Offset Safety Guide (NatureOS)

When probing for data disks or storing metadata in the boot sector (Sector 0) buffer, avoid overwriting the following offsets. These belong to the BIOS Parameter Block (BPB) and are critical for filesystem detection and operation.

## Unsafe Offsets (BPB Territory)

| Offset | Size | Name | Description |
| :--- | :--- | :--- | :--- |
| **0-2** | 3 | `BS_jmpBoot` | Jump instruction to boot code. |
| **3-10** | 8 | `BS_OEMName` | OEM System Name. |
| **11-12** | 2 | `BytsPerSec` | Bytes per sector (usually 512). |
| **13** | 1 | `SecPerClus` | Sectors per cluster. |
| **14-15** | 2 | `RsvdSecCnt` | Reserved sectors (usually 1). |
| **16** | 1 | `NumFATs` | Number of FATs (usually 2). |
| **17-18** | 2 | `RootEntCnt` | Root Directory Entries (usually 512). |
| **19-20** | 2 | `TotSec16` | **CRITICAL**: Total sectors if < 65535. Overwriting index 20 with 0x80 (DriveNum) will misreport disk size as 16MB instead of 4MB. |
| **21** | 1 | `Media` | Media descriptor. |
| **22-23** | 2 | `FATSz16` | Sectors per FAT. |
| **24-25** | 2 | `SecPerTrk` | Sectors per track. |
| **26-27** | 2 | `NumHeads` | Number of heads. |
| **28-31** | 4 | `HiddSec` | Hidden sectors. |
| **32-35** | 4 | `TotSec32` | Total sectors (32-bit). |

## Recommendation
Store ephemeral metadata in the **BIOS Intra-applications Communications Area (ICA)** at `0x0000:0x04F0`. This area remains safe during the boot process and is not overwritten by kernel or filesystem loads.

- `0x04F0`: Data Drive Number (`db`)
- `0x04F1`: Filesystem Type (`db`)
