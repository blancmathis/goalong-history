#!/bin/bash
cd "$(dirname "$0")"
chmod +x install.sh
./install.sh
STATUS=$?
echo
if [[ $STATUS -eq 0 ]]; then
  echo "Installation complete. You can close this Terminal window."
else
  echo "Installation failed with status $STATUS. See the messages above."
fi
read -r -p "Press Return to close…" _
exit $STATUS
