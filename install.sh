#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/de-setup.log"
: > "$LOG_FILE"

run_log(){ ts="$(date '+%Y-%m-%d %H:%M:%S')"; echo "[$ts] $*" | tee -a "$LOG_FILE"; }
abort(){ run_log "FATAL: $*"; exit 1; }
trap 'abort "Unexpected error at line $LINENO."' ERR

if [[ $EUID -ne 0 ]]; then echo "Harap jalankan sebagai root."; exit 1; fi

NONINTERACTIVE=false
while getopts ":yh" opt; do
  case $opt in
    y) NONINTERACTIVE=true ;;
    h) echo "Usage: $0 [-y]"; exit 0 ;;
    *) ;;
  esac
done

detect_env(){
  if [[ -r /etc/os-release ]]; then . /etc/os-release; DISTRO_ID="${ID:-unknown}"; DISTRO_NAME="${NAME:-unknown}"; DISTRO_VER="${VERSION_ID:-unknown}"; else DISTRO_ID="unknown"; DISTRO_NAME="unknown"; DISTRO_VER="unknown"; fi
  if command -v apt >/dev/null 2>&1; then PKG_MGR="apt"; elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman"; else abort "Package manager not supported (apt or pacman required)."; fi
  run_log "Detected: $DISTRO_NAME ($DISTRO_ID) $DISTRO_VER | PM: $PKG_MGR"
}

run_silently(){
  local msg="$1"; shift
  if command -v gum >/dev/null 2>&1 && [[ "${UI_TOOL:-}" == "gum" ]]; then
    gum spin --title "$msg" -- bash -c "$* &>>\"$LOG_FILE\"" || return $?
  else
    (bash -c "$* &>>\"$LOG_FILE\"") &
    local pid=$!
    printf "%s " "$msg"
    local spinner='|/-\'
    while kill -0 "$pid" >/dev/null 2>&1; do
      for c in $(echo -n "$spinner" | sed -e 's/./& /g'); do
        printf "\b%s" "$c"
        sleep 0.1
      done
    done
    wait "$pid"
    printf "\b done.\n"
  fi
}

apt_update_retry(){
  local tries=0 max=6
  while true; do
    if run_silently "Updating package index" apt update; then break; fi
    tries=$((tries+1))
    run_log "apt update failed, attempt $tries"
    if [[ $tries -ge $max ]]; then abort "apt update failed after $max attempts"; fi
    sleep 2
  done
}

apt_install(){ if [[ $# -eq 0 ]]; then return; fi; run_log "Install apt: $*"; run_silently "Installing: $*" env DEBIAN_FRONTEND=noninteractive apt install -y "$@"; }
pacman_sync_update(){ run_log "pacman -Syu"; run_silently "Refreshing packages" pacman -Syu --noconfirm; }
pacman_install(){ if [[ $# -eq 0 ]]; then return; fi; run_log "Install pacman: $*"; run_silently "Installing: $*" pacman -S --noconfirm --noprogressbar "$@"; }

prepare_ui_tools(){
  HAVE_GUM=false; HAVE_FZF=false; HAVE_WHITEL=false
  command -v gum >/dev/null 2>&1 && HAVE_GUM=true
  command -v fzf >/dev/null 2>&1 && HAVE_FZF=true
  command -v whiptail >/dev/null 2>&1 && HAVE_WHITEL=true
  UI_TOOL="none"
  if $HAVE_GUM; then UI_TOOL="gum"
  elif $HAVE_FZF; then UI_TOOL="fzf"
  elif $HAVE_WHITEL; then UI_TOOL="whiptail"
  fi
  run_log "Initial UI tool: $UI_TOOL (gum:$HAVE_GUM fzf:$HAVE_FZF whiptail:$HAVE_WHITEL)"
  ensure_gum_if_needed
}

ensure_gum_if_needed(){
  if command -v gum >/dev/null 2>&1; then
    run_log "gum detected"
    UI_TOOL="gum"
    return
  fi
  if [[ "$NONINTERACTIVE" == true ]]; then
    run_log "Non-interactive: attempting to install gum automatically"
    install_package_gum || run_log "Auto-install gum failed; will fallback to other UI tools"
  else
    if $HAVE_WHITEL; then
      if whiptail --title "Install gum?" --yesno "gum tidak terdeteksi. Ingin menginstal gum untuk UI yang lebih baik?\n(Instalasi otomatis akan dijalankan dan diarahkan ke log)" 10 60; then
        install_package_gum || run_log "Install gum gagal atau dibatalkan; fallback akan digunakan"
      else
        run_log "User chose not to install gum; fallback will be used"
      fi
    else
      read -p "gum tidak ditemukan. Ingin menginstal gum sekarang? (Y/n): " confirm
      confirm="${confirm:-Y}"
      if [[ "$confirm" =~ ^[Yy] ]]; then
        install_package_gum || run_log "Install gum gagal atau dibatalkan; fallback akan digunakan"
      else
        run_log "User declined gum installation; fallback will be used"
      fi
    fi
  fi
  if command -v gum >/dev/null 2>&1; then UI_TOOL="gum"; HAVE_GUM=true; run_log "gum terpasang dan siap digunakan"; return; fi
  if command -v fzf >/dev/null 2>&1; then UI_TOOL="fzf"; HAVE_FZF=true; run_log "Fallback to fzf"; return; fi
  if command -v whiptail >/dev/null 2>&1; then UI_TOOL="whiptail"; HAVE_WHITEL=true; run_log "Fallback to whiptail"; return; fi
  UI_TOOL="none"
  run_log "No TUI tool available; running with default non-interactive console output"
}

install_package_gum(){
  run_log "Attempting to install gum via package manager: $PKG_MGR"
  if [[ "$PKG_MGR" == "apt" ]]; then
    apt_update_retry
    if apt_install gum; then return 0; else
      run_log "apt install gum failed; trying to install via snap or download binary"
      if command -v snap >/dev/null 2>&1; then
        run_log "Attempting snap install gum"
        if run_silently "Installing gum (snap)" snap install gum; then return 0; fi
      fi
      run_log "Attempting to download gum binary from release (fallback)"
      return 1
    fi
  elif [[ "$PKG_MGR" == "pacman" ]]; then
    if pacman_install gum; then return 0; else
      run_log "pacman install gum failed; trying paru/aur helpers not supported automatically"
      return 1
    fi
  else
    return 1
  fi
}

print_banner(){
  if [[ "$UI_TOOL" == "gum" ]]; then
    gum style --align center --padding "1" --border normal --border-foreground 212 --foreground 212 "Desktop Environment Setup"
    gum style --align center "[$DISTRO_NAME | $DISTRO_VER]"
  elif [[ "$UI_TOOL" == "fzf" ]]; then
    echo "=== Desktop Environment Setup ==="
    echo "[$DISTRO_NAME | $DISTRO_VER]"
  elif [[ "$UI_TOOL" == "whiptail" ]]; then
    whiptail --title "Desktop Environment Setup" --msgbox "Distribusi: $DISTRO_NAME $DISTRO_VER" 8 50 || true
  else
    echo "=== Desktop Environment Setup ==="
    echo "[$DISTRO_NAME | $DISTRO_VER]"
  fi
}

choose_with_ui(){
  local prompt="$1"; shift
  local options=("$@")
  if [[ "$UI_TOOL" == "gum" ]]; then
    gum choose "${options[@]}"
    return
  elif [[ "$UI_TOOL" == "fzf" ]]; then
    printf "%s\n" "${options[@]}" | fzf --prompt="$prompt: " --height=10 --border
    return
  elif [[ "$UI_TOOL" == "whiptail" ]]; then
    local menu=()
    local i=1
    for opt in "${options[@]}"; do
      menu+=("$i" "$opt"); i=$((i+1))
    done
    local choice
    choice=$(whiptail --title "$prompt" --menu "$prompt" 15 60 6 "${menu[@]}" 3>&1 1>&2 2>&3) || return
    echo "${options[$((choice-1))]}"
    return
  else
    echo "${options[0]}"
    return
  fi
}

auto_defaults(){
  CHOSEN_DE="kde"; CHOSEN_DM="sddm"
  if [[ "$PKG_MGR" == "apt" ]]; then
    PKGS_COMMON=(curl)
    PKGS_DE_KDE=(task-kde-desktop)
    PKGS_DE_GNOME=(task-gnome-desktop)
    PKGS_DE_XFCE=(task-xfce-desktop)
    PKG_DM_sddm=(sddm)
    PKG_DM_gdm=(gdm3)
    PKG_VIS=(figlet lolcat gum)
  else
    PKGS_COMMON=(curl)
    PKGS_DE_KDE=(plasma)
    PKGS_DE_GNOME=(gnome)
    PKGS_DE_XFCE=(xfce4 xfce4-goodies)
    PKG_DM_sddm=(sddm)
    PKG_DM_gdm=(gdm)
    PKG_VIS=(figlet)
  fi
}

launch_tui_selection(){
  local de_options=("KDE Plasma" "GNOME" "XFCE" "Minimal")
  local dm_options=("sddm" "gdm" "none")
  local de_choice dm_choice

  de_choice=$(choose_with_ui "Pilih Desktop Environment" "${de_options[@]}")
  case "$de_choice" in
    "KDE Plasma") CHOSEN_DE="kde" ;;
    "GNOME") CHOSEN_DE="gnome" ;;
    "XFCE") CHOSEN_DE="xfce" ;;
    "Minimal") CHOSEN_DE="minimal" ;;
    *) CHOSEN_DE="kde" ;;
  esac

  dm_choice=$(choose_with_ui "Pilih Display Manager" "${dm_options[@]}")
  case "$dm_choice" in
    sddm) CHOSEN_DM="sddm" ;;
    gdm) CHOSEN_DM="gdm" ;;
    gdm3) CHOSEN_DM="gdm" ;;
    none) CHOSEN_DM="none" ;;
    *) CHOSEN_DM="sddm" ;;
  esac

  run_log "User chose DE=$CHOSEN_DE DM=$CHOSEN_DM"
}

install_visuals_if_needed(){
  local to_install=()
  for p in "${PKG_VIS[@]:-}"; do
    if ! command -v "$p" >/dev/null 2>&1; then to_install+=("$p"); fi
  done
  if [[ ${#to_install[@]} -gt 0 ]]; then
    if [[ "$PKG_MGR" == "apt" ]]; then apt_install "${to_install[@]}"; else pacman_install "${to_install[@]}"; fi
  fi
}

install_chosen(){
  run_log "Starting installation (DE=$CHOSEN_DE DM=$CHOSEN_DM)"
  if [[ "$PKG_MGR" == "apt" ]]; then
    apt_update_retry
    apt_install "${PKGS_COMMON[@]:-}"
    case "$CHOSEN_DE" in
      kde) apt_install "${PKGS_DE_KDE[@]:-}" ;;
      gnome) apt_install "${PKGS_DE_GNOME[@]:-}" ;;
      xfce) apt_install "${PKGS_DE_XFCE[@]:-}" ;;
      minimal) run_log "Minimal selected, skipping DE packages." ;;
    esac
    if [[ "$CHOSEN_DM" == "sddm" ]]; then apt_install "${PKG_DM_sddm[@]:-}"; run_silently "Enabling sddm" systemctl enable --now sddm || run_log "Enable sddm failed"; fi
    if [[ "$CHOSEN_DM" == "gdm" ]]; then apt_install "${PKG_DM_gdm[@]:-}"; run_silently "Enabling gdm" systemctl enable --now gdm || run_log "Enable gdm failed"; fi
  else
    pacman_sync_update
    pacman_install "${PKGS_COMMON[@]:-}"
    case "$CHOSEN_DE" in
      kde) pacman_install "${PKGS_DE_KDE[@]:-}" sddm plasma-wayland-session ;;
      gnome) pacman_install "${PKGS_DE_GNOME[@]:-}" gnome gnome-extra ;;
      xfce) pacman_install "${PKGS_DE_XFCE[@]:-}" ;;
    esac
    if [[ "$CHOSEN_DM" == "sddm" ]]; then pacman_install "${PKG_DM_sddm[@]:-}"; run_silently "Enabling sddm" systemctl enable --now sddm || run_log "Enable sddm failed"; fi
    if [[ "$CHOSEN_DM" == "gdm" ]]; then pacman_install "${PKG_DM_gdm[@]:-}"; run_silently "Enabling gdm" systemctl enable --now gdm || run_log "Enable gdm failed"; fi
  fi
}

finalize(){
  run_log "Cleaning up"
  if [[ "$PKG_MGR" == "apt" ]]; then run_silently "Autoremove" apt autoremove -y; run_silently "Autoclean" apt autoclean -y; else run_silently "Cleaning pacman cache" pacman -Sc --noconfirm; fi
  if [[ "$UI_TOOL" == "gum" ]]; then gum style --align center "Instalasi selesai. Sistem akan reboot otomatis dalam 6 detik." ; else echo "Instalasi selesai. Reboot otomatis dalam 6 detik."; fi
  sleep 6
  run_log "Rebooting now"
  reboot
}

main(){
  detect_env
  prepare_ui_tools
  print_banner
  auto_defaults
  if $NONINTERACTIVE; then
    run_log "Non-interactive mode: using defaults"
  else
    if [[ "$UI_TOOL" != "none" ]]; then
      launch_tui_selection
    else
      run_log "No TUI tools found, running non-interactive defaults"
    fi
  fi
  install_visuals_if_needed
  install_chosen
  finalize
}

main "$@"
