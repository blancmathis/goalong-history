#!/bin/bash

install_goalong_cli_link() {
  local app_path="$1"
  local bin_directory="${2:-$HOME/.local/bin}"
  local cli_binary="$app_path/Contents/MacOS/goalong"
  local link_path="$bin_directory/goalong"
  local temporary_link

  if [[ ! -d "$app_path" || -L "$app_path" || ! -x "$cli_binary" || -L "$cli_binary" ]]; then
    echo "Goalong CLI was not installed because the verified app does not contain a regular executable at $cli_binary" >&2
    return 1
  fi
  if [[ -e "$bin_directory" || -L "$bin_directory" ]]; then
    if [[ ! -d "$bin_directory" || -L "$bin_directory" || ! -w "$bin_directory" ]]; then
      echo "Goalong CLI was not linked because $bin_directory is not a safe writable directory." >&2
      return 0
    fi
  else
    /bin/mkdir -p "$bin_directory"
    /bin/chmod 755 "$bin_directory"
  fi

  if [[ -e "$link_path" || -L "$link_path" ]]; then
    if [[ ! -L "$link_path" ]]; then
      echo "Goalong CLI was not linked because an existing non-symlink command is present at $link_path" >&2
      return 0
    fi
    local existing_target
    existing_target="$(/usr/bin/readlink "$link_path")"
    if [[ "$existing_target" == "$cli_binary" ]]; then
      return 0
    fi
    case "$existing_target" in
      */Goalong\ History.app/Contents/MacOS/goalong) ;;
      *)
        echo "Goalong CLI was not linked because $link_path points to an unrelated target." >&2
        return 0
        ;;
    esac
  fi

  temporary_link="$bin_directory/.goalong.$$.tmp"
  if [[ -e "$temporary_link" || -L "$temporary_link" ]]; then
    echo "Goalong CLI temporary link already exists unexpectedly at $temporary_link" >&2
    return 1
  fi
  /bin/ln -s "$cli_binary" "$temporary_link"
  /bin/mv -f "$temporary_link" "$link_path"
}
