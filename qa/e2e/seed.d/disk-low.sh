#!/usr/bin/env bash
# seed:disk-low (J-0998): « Espace disque presque plein » banner with « Gérer le stockage… ». Env: DATA. Exit 3 = free space and journals are read at launch. Throwaway CI runner only.
set -u
IMG="${DATA}.t046-disk-low.sparseimage"; TMPM="${DATA}.t046-disk-low-mnt"; MARK="${DATA}.t046-disk-low.mounted"
case "${1:-}" in
  seed)
    # Banner: GoalongAttentionBanner.swift:26 notice = .lowSpace(free) when recording is expected and StorageHealth.isLow(model.freeDiskBytes);
    # isLow = free < 2 GiB (StorageHealth.swift:10,47-49). Button « Gérer le stockage… » :111/120 (secondary, :108-109).
    # freeDiskBytes = StorageHealth.availableBytes() of AppPaths.applicationSupportDirectory (DashboardViewModel.swift:246,1046-1049; StorageHealth.swift:33-41:
    # volumeAvailableCapacityForImportantUsage, else statfs): the volume that holds DATA. Re-read every 60 s, first read at launch.
    # No sda filling: a 1 GB disk image holds a copy of DATA and is mounted over DATA (its free space is < 1 GB). Unseed detaches it, original DATA reappears untouched.
    [[ -e "$MARK" ]] && exit 0
    hdiutil create -size 1g -fs HFS+ -volname t046-low -type SPARSE -ov "${IMG%.sparseimage}" >/dev/null || exit 1
    mkdir -p "$TMPM" "$DATA"
    hdiutil attach "$IMG" -nobrowse -noverify -mountpoint "$TMPM" >/dev/null || exit 1
    # Copy the current data (config, consent, journals) so the app starts from the same state; ownership off (no root needed).
    cp -Rp "$DATA"/. "$TMPM"/ 2>/dev/null
    hdiutil detach "$TMPM" >/dev/null || exit 1
    hdiutil attach "$IMG" -nobrowse -noverify -owners off -mountpoint "$DATA" >/dev/null || exit 1
    : > "$MARK"
    rmdir "$TMPM" 2>/dev/null
    exit 3 ;;
  unseed)
    # Detach the image from DATA (original folder content was hidden, not modified), then delete image and markers.
    if [[ -e "$MARK" ]]; then hdiutil detach "$DATA" >/dev/null 2>&1 || hdiutil detach -force "$DATA" >/dev/null 2>&1; fi
    rm -f "$IMG" "$MARK"; rmdir "$TMPM" 2>/dev/null
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
