# ClaudeOS v2.0 - Build Guide

A real bootable x86 operating system written in pure assembly. Runs directly
on the CPU - no OS, no runtime, no libraries. Real-mode shell with full BIOS
access, plus a 32-bit protected-mode graphical desktop with a window manager,
mouse support, and direct hardware drivers.

-

## Requirements

| Tool   | Get it from                                              |
|-|-|
| NASM   | https://nasm.us/pub/nasm/releasebuilds/?C=M&O=D         |
| Python | https://www.python.org/downloads/                        |
| QEMU   | https://www.qemu.org/download/#windows                   |

**First-time Python setup** (one time only):
```
pip install pycdlib
```

-

## Step 1 - Build

```
build.bat
```

Produces `claudeos.iso`.

```
build.bat run
```

Builds and launches in QEMU immediately.

-

## Step 2 - Run in QEMU

### Quick launch
```
build.bat run
```

### Full command
```
qemu-system-x86_64 ^
  -cdrom claudeos.iso ^
  -drive format=raw,file=data.img,if=ide,index=3 ^
  -boot d ^
  -m 64M ^
  -cpu qemu64 ^
  -smp 1 ^
  -vga std ^
  -rtc base=localtime ^
  -audiodev id=snd,driver=dsound ^
  -machine pcspk-audiodev=snd ^
  -nic user,model=e1000 ^
  -display sdl,window-close=on ^
  -name "ClaudeOS" ^
  -no-reboot
```

> **Linux/macOS audio:** replace `-audiodev id=snd,driver=dsound` with
> `-audiodev id=snd,driver=pa` (PulseAudio) or `driver=alsa`.

-

## Real-Mode Shell Commands

| Command              | What it does                              |
|-|-|
| `help`               | Show all commands (paged)                 |
| `echo <text>`        | Print text                                |
| `clear`              | Clear the screen                          |
| `color [XX]`         | Set shell colour (e.g. `color 5F`)        |
| `calc <n> <op> <n>`  | Calculator (`+` `-` `*` `/`)             |
| `beep`               | Sound the PC speaker                      |
| `fortune`            | Random quote                              |
| `guess`              | Number guessing game (1-100)              |
| `colors`             | Show all 16 colour swatches               |
| `ascii`              | ASCII table (32-126)                      |
| `sys`                | System snapshot (date/time/uptime/memory) |
| `date`               | Show RTC date                             |
| `time`               | Show RTC time                             |
| `setdate`            | Set RTC date                              |
| `settime`            | Set RTC time                              |
| `probe`              | Verify real mode                          |
| `drivers`            | Show loaded real-mode drivers             |
| `ls`                 | List filesystem files                     |
| `run <name>`         | Run an app from ClaudeFS                  |
| `reboot`             | Reboot the machine                        |
| `halt`               | Halt the CPU                              |
| `pm`                 | Switch to 32-bit protected mode + desktop |

-

## Protected-Mode Desktop

Type `pm` in the real-mode shell to enter the graphical desktop.

- **Mouse** - PS/2 mouse, full cursor support
- **Terminal** - type commands in the terminal window
- **Icons** - click Terminal / Files on the left sidebar
- **Windows** - drag title bars to move, click  to close
- **Taskbar** - click buttons to switch between open windows
- **PrtSc** - capture screenshot, then `savescr` to save to disk

### Terminal Commands (PM)

| Command              | What it does                              |
|-|-|
| `help`               | Show all PM commands                      |
| `ver`                | Version info                              |
| `clear`              | Clear terminal                            |
| `echo <text>`        | Print text                                |
| `calc <n> <op> <n>`  | 32-bit signed calculator                  |
| `probe`              | Confirm 32-bit protected mode             |
| `drivers`            | Show loaded PM drivers                    |
| `ls`                 | List files (ISO + data disk)              |
| `cat <name>`         | Print file contents to terminal           |
| `rm <name>`          | Delete file from data disk                |
| `hexdump <name>`     | Hex + ASCII dump of file                  |
| `pci`                | Enumerate all PCI devices                 |
| `ifconfig`           | Show NIC MAC address and link status      |
| `arp`                | Show ARP cache                            |
| `arping <ip>`        | Send ARP request                          |
| `ping <ip>`          | Send ICMP echo                            |
| `dns <hostname>`     | Resolve hostname via DNS                  |
| `clock`              | Open stopwatch/timer window               |
| `stopwatch`          | Stopwatch (start/stop/reset)              |
| `timer MM:SS`        | Countdown timer                           |
| `files`              | Open file browser window                  |
| `savescr`            | Save pending screenshot to data disk      |
| `exit`               | Return to real-mode shell                 |

-

## Wallpaper

Drop a file named `wallpaper.bmp` into the `apps/` folder before building.

**Requirements:**
- Format: BMP, 8-bit indexed (256 colour)
- Size: exactly 640480 pixels

-

## Network Stack

| Layer     | Status      |
|-|-|
| PCI       |  Done     |
| e1000 NIC |  Done     |
| Ethernet  |  Done     |
| ARP       |  Done     |
| IP        |  Done     |
| ICMP/ping |  Done     |
| UDP       |  Done     |
| DNS       |  Done     |

-

## Project Structure

```
claudeos/
+-- build.bat                   Windows build + run script
+-- Makefile                    Linux/macOS build script
+-- mkfs.py                     Filesystem packer
+-- mkiso.py                    Pure Python ISO builder
+-- inject.py                   Data disk file tool
+-- README.md                   This file
+-- boot.asm                    512-byte MBR bootloader
+-- stage2.asm                  Stage 2 loader
+-- kernel.asm                  Kernel entry point + includes
+-- sdk.asm                     App SDK (syscall macros)
|
+-- apps/                       Files packed into ClaudeFS
|
+-- core/                       Real-mode hardware abstractions
+-- drivers/                    Real-mode driver registry
+-- shell/                      Real-mode shell
+-- commands/                   Real-mode commands
|
+-- pm/                         32-bit protected mode
    +-- pm_shell.asm            PM entry, main loop, command dispatch
    +-- pm_commands.asm         ls, cat, rm, hexdump, savescr, etc.
    +-- pm_data.asm             PM variables and strings
    +-- pm_drivers.asm          PM driver registry
    +-- wm.asm                  Window manager
    +-- terminal.asm            Terminal emulator
    +-- gfx.asm                 Framebuffer primitives
    +-- font.asm                88 bitmap font renderer
    +-- mouse.asm               PS/2 mouse driver
    +-- wallpaper.asm           Desktop wallpaper loader
    +-- icons.asm               Desktop icon system
    +-- fs_pm.asm               ISO filesystem reader
    +-- fs_data.asm             ClaudeFS data disk (read/write)
    +-- bios_disk.asm           BIOS INT 13h disk I/O from PM
    +-- irq.asm                 IDT, PIC, PIT timer
    +-- net/
        +-- pci.asm             PCI bus enumerator
        +-- e1000.asm           Intel 82540EM NIC driver
        +-- eth.asm             Ethernet II framing
        +-- arp.asm             ARP (address resolution)
        +-- ip.asm              IPv4
        +-- icmp.asm            ICMP / ping
        +-- udp.asm             UDP + DNS resolver
```

-
-

## Physical Memory Map

Every large buffer has a fixed address. **Do not place new buffers without checking this table first** - silent overlaps are the #1 source of hard-to-diagnose bugs (e.g. the wallpaper buffer once sat at `0x100000` and silently bulldozed the e1000 descriptor rings on every boot).

| Range                   | Size    | Owner                                      |
|-|-|-|
| `0x00000 - 0x003FF`   | 1 KB    | IVT (Interrupt Vector Table)               |
| `0x00400 - 0x004FF`   | 256 B   | BIOS Data Area                             |
| `0x07C00 - 0x07DFF`   | 512 B   | Stage 1 bootloader                         |
| `0x07D00 - 0x07DFF`   | 256 B   | BD_DAP (bios_disk DAP scratch)             |
| `0x07E00 - 0x07EFF`   | 256 B   | BD_STUB (bios_disk real-mode trampoline)   |
| `0x07F00 - 0x07FFF`   | 256 B   | BD_STUB scratch (GDTR/IDTR/ESP save)       |
| `0x08000 - 0x19FFF`   | ~72 KB  | Kernel binary (grows upward)               |
| `0x70000 - 0x7FFFF`   | 64 KB   | BD_BOUNCE (BIOS disk I/O bounce buffer)    |
| `0x80000 - 0x8A000`   | ~40 KB  | Data disk header + directory (stage2 load) |
| `0x9E000`             | -       | PM stack top (grows downward)              |
| `0xA0000 - 0xBFFFF`   | 128 KB  | VGA / display memory                       |
| `0xC0000 - 0xFFFFF`   | 256 KB  | BIOS ROM / shadow - DO NOT WRITE HERE     |
| `0x101000 - 0x1010FF` | 256 B   | e1000 TX descriptor ring (16 x 16 bytes)   |
| `0x101100 - 0x1011FF` | 256 B   | e1000 RX descriptor ring (16 x 16 bytes)   |
| `0x102000 - 0x111FFF` | 64 KB   | e1000 TX packet buffers (16 x 2048 bytes)  |
| `0x112000 - 0x119FFF` | 32 KB   | e1000 RX packet buffers (16 x 2048 bytes)  |
| `0x200000 - 0x24AFFF` | 300 KB  | WP_BUF (wallpaper decoded pixels)          |
| `0x24B000 - 0x24B0FF` | 256 B   | WP_REMAP (wallpaper palette remap table)   |
| `0x300000 - 0x34AFFF` | ~308 KB | SCR_BUF (screenshot BMP build area)        |
| `0x500000 - 0x54AFFF` | 300 KB  | GFX_SHADOW (framebuffer shadow buffer)     |
| `0x600000 - 0x64AFFF` | 300 KB  | SCR_CAPTURE (PrtSc snapshot)               |
| `0x650000 - 0x6507FF` | 2 KB    | TCP_TX_BUF (outbound segment staging)      |
| `0x650800 - 0x6527FF` | 8 KB    | TCP_RX_BUF (inbound payload reassembly)    |


## How It Works

The BIOS loads `boot.asm` (512 bytes) at `0x7C00`. Stage 2 uses INT 13h LBA
reads to load the kernel and ClaudeFS into memory.

The kernel initialises real-mode drivers and enters a command shell. Typing
`pm` switches to 32-bit protected mode: GDT loaded, `CR0.PE=1`, far jump to
`pm_entry`. VBE graphics (640480 8bpp), PS/2 mouse, and the graphical
desktop start up.

No C. No libraries. No OS. Just x86 assembly and direct hardware.
