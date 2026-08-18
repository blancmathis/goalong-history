#!/bin/bash
cd "$(dirname "$0")"
chmod +x uninstall.sh
./uninstall.sh
STATUS=$?
echo
read -r -p "Press Return to close…" _
exit $STATUS
