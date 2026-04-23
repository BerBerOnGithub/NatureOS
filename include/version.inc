; ===========================================================================
; NatureOS/include/version.inc - Centralized version strings
; ===========================================================================

%define OS_NAME          "NatureOS"
%define OS_VERSION       "0.1"
%define OS_BUILD         "0.1.1"
%define OS_VER_SHORT     "NatureOS 0.1.1-alpha"
%define OS_VER_TEXT      "NatureOS version 0.1.1"
%define KERNEL_VER       "0.1.0-release"
%define OS_BUILD_DATE    "2026-04-23"
%define OS_AUTHOR        "Ethereal Software"
%define OS_ARCH_RM       "x86 16-bit"
%define OS_ARCH_PM       "32-bit Protected Mode"
%define RELEASE_CHANNEL  "stable"

; Filesystem Names
%define FS_NAME          "NatureFS"
%define FS_DATA_NAME     "NatureFS Data Disk"

; Magic numbers
%define FS_MAGIC         "CLFS"
%define FS_MAGIC_VAL     0x53464C43   ; 'CLFS'
%define FS_DATA_MAGIC    "CLFD"
%define FS_DATA_MAGIC_VAL 0x44464C43  ; 'CLFD'
