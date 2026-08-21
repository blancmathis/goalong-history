#!/bin/bash
cd "$(dirname "$0")" || exit 1
chmod +x uninstall.sh

CHOICE="Keep data"
if command -v osascript >/dev/null 2>&1; then
  CHOICE="$(osascript <<'APPLESCRIPT'
set answer to display dialog "Remove Goalong History from this Mac?" with title "Uninstall Goalong History" buttons {"Cancel", "Remove app + data", "Keep data"} default button "Keep data" cancel button "Cancel" with icon caution
return button returned of answer
APPLESCRIPT
  )" || exit 0
fi

if [[ "$CHOICE" == "Remove app + data" ]]; then
  ./uninstall.sh --purge-data
else
  ./uninstall.sh
fi
STATUS=$?
echo
read -r -p "Press Return to close… " _
exit $STATUS
