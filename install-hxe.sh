#!/usr/bin/env bash
#
# install-hxe.sh
# Production-ready, non-interactive installer for SAP HANA Express Edition on Linux x64.
# Intended to be run via Azure Custom Script Extension on a fresh VM.
#

set -euo pipefail

########################################
# CONFIGURATION (EDIT THESE)
########################################

# **Mandatory:** HANA system password (SYSTEM, XSA_ADMIN, etc.)
HXE_MASTER_PASSWORD="Appr0ved!!"

# **Mandatory:** SID and instance number
HXE_SID="BMK"
HXE_INSTANCE_NUMBER="21"

# **Installer source:**
# Option 1: Direct download (if SAP provides a URL for HXE installer image)
HXE_INSTALLER_URL="https://hanazipfiles.blob.core.windows.net/tgz?sp=r&st=2026-06-28T19:04:42Z&se=2026-07-01T03:19:42Z&spr=https&sv=2026-02-06&sr=c&sig=0ohd2UWl%2FCOKR8TK9y6q404Sgnx9j%2BVtlf7G9mzK1%2Bg%3D"

# Option 2: Pre-mounted/attached volume path (comment URL above and set this)
HXE_INSTALLER_LOCAL_PATH="${HXE_INSTALLER_LOCAL_PATH:-}"

# Working directory
WORKDIR="/hana-installer"
LOGFILE="/var/log/install-hxe.log"

########################################
# HELPER FUNCTIONS
########################################

log() {
  echo "[$(date -Iseconds)] $*" | tee -a "$LOGFILE"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "Script must be run as root."
  fi
}

check_os() {
  log "Checking OS..."
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    log "Detected OS: $NAME ($ID), version $VERSION_ID"
  else
    fail "/etc/os-release not found; unsupported OS."
  fi
}

install_prereqs() {
  log "Installing prerequisites..."

  if command -v zypper >/dev/null 2>&1; then
    # SLES
    zypper --non-interactive refresh || true
    zypper --non-interactive install \
      glibc \
      libstdc++6 \
      libgcc_s1 \
      libaio1 \
      libopenssl1_1 \
      net-tools \
      wget \
      tar \
      hostname || fail "Failed to install prerequisites via zypper."
  elif command -v apt-get >/dev/null 2>&1; then
    # Ubuntu/Debian
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      libc6 \
      libstdc++6 \
      libgcc1 \
      libaio1 \
      openssl \
      net-tools \
      wget \
      tar \
      hostname || fail "Failed to install prerequisites via apt-get."
  else
    fail "Unsupported package manager. Need zypper or apt-get."
  fi
}

prepare_filesystem() {
  log "Preparing filesystem for HANA (basic example)..."

  # Create base directories if not present
  mkdir -p /hana/data /hana/log /hana/shared /usr/sap

  # In production, you’d mount dedicated disks here (LVM, XFS, etc.).
  # This script assumes disks are already partitioned and mounted by the platform.
}

download_installer() {
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  log "Downloading installer from: $HXE_INSTALLER_URL"
  wget -O hxexsa.tgz "$HXE_INSTALLER_URL" || fail "Failed to download HXE installer."

  log "Extracting installer..."
  tar -xvf hxexsa.tgz || fail "Failed to extract installer."
}

create_response_file() {
  log "Creating response file for silent installation..."

  # This is a generic example; adjust keys to match your HXE installer’s sample_response.txt.
  cat > "$WORKDIR/response_hxe.txt" <<EOF
AGREE_TO_SAP_LICENSE=true
RUN_SILENT=true

sapinst.sapinstInstanceNumber=${HXE_INSTANCE_NUMBER}
sapinst.sapinstSID=${HXE_SID}

systemPassword=${HXE_MASTER_PASSWORD}
masterPassword=${HXE_MASTER_PASSWORD}
xsAdminPassword=${HXE_MASTER_PASSWORD}
EOF

  chmod 600 "$WORKDIR/response_hxe.txt"
}

run_installer() {
  log "Running HXE installer in silent mode..."

  # Locate installer binary (adjust path to match extracted structure)
  # Common patterns: ./HXEInstaller, ./setup.bin, or ./hxe_installer/setup.bin
  local installer_bin

  if [[ -x "$WORKDIR/HXEInstaller" ]]; then
    installer_bin="$WORKDIR/HXEInstaller"
  elif [[ -x "$WORKDIR/setup.bin" ]]; then
    installer_bin="$WORKDIR/setup.bin"
  else
    # Try to find something executable
    installer_bin="$(find "$WORKDIR" -maxdepth 3 -type f -name 'HXEInstaller' -o -name 'setup.bin' | head -n 1 || true)"
  fi

  if [[ -z "${installer_bin:-}" ]]; then
    fail "Installer binary not found in $WORKDIR. Check extracted content."
  fi

  log "Using installer binary: $installer_bin"

  # Example for InstallAnywhere-style silent install:
  #   setup.bin -f response_hxe.txt -i silent -DAGREE_TO_SAP_LICENSE=true -DRUN_SILENT=true
  # Example for HXEInstaller:
  #   HXEInstaller --batch --read_password_from_file=<file> ...
  #
  # Adjust this command to match your specific HXE image documentation.

  "$installer_bin" \
    -f "$WORKDIR/response_hxe.txt" \
    -i silent \
    -DAGREE_TO_SAP_LICENSE=true \
    -DRUN_SILENT=true \
    >> "$LOGFILE" 2>&1 || fail "HXE installer failed. Check $LOGFILE."
}

post_install_config() {
  log "Running post-install configuration..."

  # Example: enable HANA to start on boot (single-host)
  if [[ -x /usr/sap/${HXE_SID}/HDB${HXE_INSTANCE_NUMBER}/HDB ]]; then
    log "Enabling HANA auto-start via systemd..."

    cat > /etc/systemd/system/sap-hana-${HXE_SID}.service <<EOF
[Unit]
Description=SAP HANA ${HXE_SID}
After=network.target

[Service]
Type=forking
ExecStart=/usr/sap/${HXE_SID}/HDB${HXE_INSTANCE_NUMBER}/HDB start
ExecStop=/usr/sap/${HXE_SID}/HDB${HXE_INSTANCE_NUMBER}/HDB stop
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sap-hana-${HXE_SID}.service
    systemctl start sap-hana-${HXE_SID}.service || fail "Failed to start HANA service."
  else
    log "HANA binaries not found at expected path; skipping systemd service creation."
  fi

  # Open typical ports (example only; in Azure, NSG should handle most of this)
  if command -v firewall-cmd >/dev/null 2>&1; then
    log "Configuring firewall (firewalld)..."
    firewall-cmd --permanent --add-port=39013/tcp || true
    firewall-cmd --permanent --add-port=39017/tcp || true
    firewall-cmd --reload || true
  elif command -v ufw >/dev/null 2>&1; then
    log "Configuring firewall (ufw)..."
    ufw allow 39013/tcp || true
    ufw allow 39017/tcp || true
  fi
}

summary() {
  log "SAP HANA Express installation completed."
  log "SID: ${HXE_SID}, Instance: ${HXE_INSTANCE_NUMBER}"
  log "Master password (SYSTEM, XSA_ADMIN, etc.): (hidden)"
  log "Check HANA status with: ps -ef | grep hdb | grep -v grep"
}

########################################
# MAIN
########################################

main() {
  require_root
  check_os
  install_prereqs
  prepare_filesystem
  download_installer
  create_response_file
  run_installer
  post_install_config
  summary
}

main "$@"
