#!/bin/bash
cd "$(dirname "$0")" || exit 1
printf '\033]0;Goalong History Setup\007'
chmod +x install.sh scripts/*.sh 2>/dev/null || true
./install.sh "$@"
STATUS=$?

if [[ $STATUS -ne 0 ]]; then
  echo
  echo "Goalong History was not installed. The details above explain what needs attention."
  echo
  read -r -p "Press Return to close… " _
fi
exit $STATUS
