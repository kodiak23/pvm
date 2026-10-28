#!/usr/bin/env bash
# shellcheck disable=SC2016

# run this script from your proxmox host using the following:
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/kodiak23/pvm/refs/heads/main/pvm-init.sh)"

set -eo pipefail

###   ------   Main Functions   ------   ###

_main() {
  _prerequisites
  _extras
  _install
  _cleanup
}

_prerequisites() {
  _define_variables
  _pve_check
  _root_check
  _snippets_check
  _homebrew_check
  _package_check
}

_extras() {
  _setup_pveadmin_user
  _install_homebrew
}

_install() {
  _setup_pvm
}

_cleanup() {
  _update_homebrew
  _update_proxmox
  _reboot
}

###   ------   Prerequisite Functions   ------   ###

_define_variables() {
  brew_installed=false
  brew_user=""
  package_list=(
    "git"
    "gum"
    "just"
    "fd"
    "sd"
  )
  pvm_repo="https://github.com/kodiak23/pvm"
  # user_id="$EUID"
  # user_1000=$(id -un 1000; echo $?)
  # as_user_1000=$([[ "$EUID" == "1000" ]]; echo $?)
}

__pve_check() {
  # Exit script if not running on proxmox
  [[ -d /etc/pve ]] || {
    echo "This script is only designed to be run on Proxmox"
    exit 1
  }
}

__root_check() {
  # Exit script if not running as root
  [[ "$EUID" ]] || {
    echo "This script is only designed to be run as root on the Proxmox node"
    exit 1
  }
}

__snippets_check() {
  # Exit script if snippets directory is not configured
  grep -q "snippets" /etc/pve/storage.cfg || {
    echo "Your Proxmox node needs to be configured with a snippets storage directory before running this script"
    exit 1
  }
}

__homebrew_check() {
  # Check if homebrew is installed
  [[ -e /home/linuxbrew/.linuxbrew/bin/brew ]] && {
    brew_installed=true
    brew_user="$(stat -f '%u' /home/linuxbrew/.linuxbrew)"
  }
}

__package_check() {
  # Install packages required for this script

  local not_installed=()

  for package in "${package_list[@]}"; do
    if [[ ! $(command -v "$package") ]]; then
      not_installed+=("$package")
    fi
  done

  if [[ "${#not_installed[@]}" != 0 ]]; then
    echo "Installing packages required for PVM"
    if [[ $brew_installed ]]; then
      for package in "${not_installed[@]}"; do
        runuser "$brew_user" -c 'cd "$HOME" && /home/linuxbrew/.linuxbrew/bin/brew install "$package"'
      done
    else
      apt update
      for package in "${not_installed[@]}"; do
        apt install -y "$package"
      done
    fi
  fi
}

###   ------   Extra Functions   ------   ###

__setup_pveadmin_user() {
  # Add new PVEAdmin user

  if gum confirm "Would you like to set up a non-root PVEAdmin user?"; then

    if [[ $(id -un 1000) ]]; then
      username=$(id -un 1000)
      homedir="/mnt/cephfs/pve/snippets/$username"
    else
      username=$(gum input --prompt "Enter username: ")
      homedir="/mnt/cephfs/pve/snippets/$username"
      adduser --uid 1000 --home "$homedir" "$username"
    fi

    gpasswd -a "$username" sudo
    pveum user add "$username"@pam || true
    pveum acl modify / --roles PVEAdmin --users "$username"@pam
    echo "User: $username"
    echo "Home Directory: $homedir"
  fi
}

__install_homebrew() {
  # Create the home directory for Homebrew with user permissions
  [[ -d /home/linuxbrew/.linuxbrew ]] || {
    mkdir -p /home/linuxbrew/.linuxbrew/
    chown 1000:1000 /home/linuxbrew/.linuxbrew/
  }

  # brew_user="$(stat -f '%u' /home/linuxbrew/.linuxbrew)"
  # [[ $EUID == $brew_user ]] && as_brew_user=true || as_brew_user=false

  # Install homebrew as the user
  [[ -e /home/linuxbrew/.linuxbrew/bin/brew ]] || {
    runuser "$username" -c 'cd "$HOME" && echo "Installing Homebrew" && gum spin --title "Installing..." -- bash -c "NONINTERACTIVE=1 $(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  }

  # Clone dotfiles repo as the user
  [[ -d "$homedir"/.config ]] || {
    runuser "$username" -c 'echo "Cloning dotfiles to root $HOME/.config" && gum spin --title "Cloning..." -- git clone https://forge.klkosak.com/kodiak23/dotfiles -b pve "$HOME"/.config'
  }

  # Add config source to bashrc as the user
  grep -q ".config/bash/bashrc" "$homedir"/.bashrc || {
    runuser "$username" -c 'echo "Sourcing custom bashrc file" && echo "[[ -e $HOME/.config/bash/bashrc ]] && source $HOME/.config/bash/bashrc" >> "$HOME"/.bashrc'
  }

  # Install cli-essentials as the user
  runuser "$username" -c 'cd "$HOME" && echo "Installing cli-essential packages" && /home/linuxbrew/.linuxbrew/bin/brew bundle install --file "$HOME"/.config/homebrew/cli-essentials.brewfile'

  # Uninstall debian packages if they have been successfully installed with homebrew
  [[ -e /home/linuxbrew/.linuxbrew/bin/git ]] && [[ -e /usr/bin/git ]] && echo "Uninstalling git from apt now that it is installed via Homebrew" && gum spin --title "Uninstalling..." -- bash -c "apt remove -y git && apt autoremove -y"
  [[ -e /home/linuxbrew/.linuxbrew/bin/gum ]] && [[ -e /usr/bin/gum ]] && echo "Uninstalling gum from apt now that it is installed via Homebrew" && gum spin --title "Uninstalling..." -- bash -c "apt remove -y gum && apt autoremove -y"

  # Source bash file again now that the gum command needs to point to the homebrew install
  # shellcheck disable=SC1091
  source "$HOME"/.bashrc

}

###   ------   Install Functions   ------   ###

__setup_pvm() {
  # Clone PVM repo to snippets directory
  local snippetsdir=""
  local pvmdir="$snippetsdir/pvm"
  [[ -d "$pvmdir" ]] || {
    echo "Cloning PVM to $pvmdir"
    gum spin --title "Cloning..." -- git clone "$pvm_repo" "$pvmdir"
  }
  # Add pvm alias to bashrc
  grep -q "alias pvm" "$HOME"/.bashrc || {
    echo "Adding pvm alias to bashrc"
    echo '[[ -d "$pvmdir" ]] && alias pvm="just --justfile $pvmdir/justfile"' >>"$HOME"/.bashrc
    # shellcheck disable=SC1091
    source "$HOME"/.bashrc
  }
}

###   ------   Cleanup Functions   ------   ###

_update_homebrew() {
  if $brew_installed; then
    brew update && brew upgrade -y
  fi
}

_update_proxmox() {
  # Update Proxmox
  if gum confirm "Would you like to update Proxmox?"; then
    if gum confirm "Have you disabled the PVE enterpise repositories and enabled the no-subscription repositories from the GUI?"; then
      echo "Updating Proxmox" && gum spin --title "Updating..." -- bash -c "apt update && apt upgrade -y && apt autoremove -y"
    else
      echo "Please update the repositories and update Proxmox from the GUI"
    fi
  fi
}

_reboot() {
  # Restart
  echo "Setup Complete!"
  gum confirm "Rebooting is recommended. Would you like to reboot now?" && systemctl reboot
}

###   ------   Run Main   ------   ###
_main
