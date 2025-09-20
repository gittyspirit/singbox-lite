#!/bin/bash

# ==============================================================================
# Sing-Box Multi-Protocol Installation and Configuration Script
# This script automates the installation of Sing-Box and sets up a configuration
# for VLESS Reality, TUIC v5, Hysteria 2, VMess over WebSocket, and VLESS over
# WebSocket with TLS.
# It now includes an option to configure a Cloudflare Argo Tunnel for VMess-WS
# with a custom host header.
#
# NOTE: This script must be run as root or with sudo.
# ==============================================================================

# --- Configuration ---
INSTALL_PATH="/usr/local/bin"
CONFIG_PATH="/etc/sing-box"
SERVICE_NAME="sing-box"
LOG_PATH="/var/log/sing-box"
SINGBOX_REPO_URL="[https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-$(uname](https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-$(uname) -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g').zip"
CLOUDFLARED_REPO_URL="[https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-$(uname](https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-$(uname) -s | tr '[:upper:]' '[:lower:]')-$(uname -m).zip"
CLOUDFLARED_PATH="/usr/local/bin/cloudflared"
CLOUDFLARED_SERVICE="cloudflared"

# VLESS Reality Hostnames for SNI
REALITY_DEST_HOSTNAMES=(
    "bing.com"
    "[www.microsoft.com](https://www.microsoft.com)"
    "[www.google.com](https://www.google.com)"
    "discord.com"
    "[www.cloudflare.com](https://www.cloudflare.com)"
)

# --- Functions ---

# Check for root privileges.
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root or with sudo."
        exit 1
    fi
}

# Install necessary dependencies.
install_dependencies() {
    echo "Installing required dependencies (unzip, wget, jq, uuidgen, base64, openssl)..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install unzip wget jq uuid-runtime openssl -y
    elif command -v dnf >/dev/null 2>&1; then
        dnf install unzip wget jq uuidgen openssl -y
    elif command -v yum >/dev/null 2>&1; then
        yum install unzip wget jq uuidgen openssl -y
    else
        echo "Could not find a package manager (apt, dnf, yum). Please install the dependencies manually."
        exit 1
    fi
}

# Download and install sing-box.
install_singbox() {
    echo "Downloading and installing Sing-Box..."
    wget -q --show-progress -O /tmp/sing-box.zip "${SINGBOX_REPO_URL}"
    unzip -o /tmp/sing-box.zip -d /tmp/sing-box_temp
    mv /tmp/sing-box_temp/sing-box "${INSTALL_PATH}/sing-box"
    chmod +x "${INSTALL_PATH}/sing-box"
    rm -rf /tmp/sing-box.zip /tmp/sing-box_temp
}

# Generate keys and UUID.
generate_keys() {
    echo "Generating keys and UUID for the configuration..."
    UUID=$(uuidgen)
    REALITY_KEYPAIR=$(${INSTALL_PATH}/sing-box generate reality-keypair)
    REALITY_PRIVATE_KEY=$(echo "${REALITY_KEYPAIR}" | grep 'PrivateKey' | awk '{print $2}')
    REALITY_PUBLIC_KEY=$(echo "${REALITY_KEYPAIR}" | grep 'PublicKey' | awk '{print $2}')
    REALITY_SHORT_ID=$(openssl rand -hex 8)

    echo "UUID: ${UUID}"
    echo "Reality Public Key: ${REALITY_PUBLIC_KEY}"
    echo "Reality Short ID: ${REALITY_SHORT_ID}"
}

# Install and configure Cloudflare Argo Tunnel.
install_argo() {
    echo "Downloading and installing cloudflared..."
    wget -q --show-progress -O /tmp/cloudflared.zip "${CLOUDFLARED_REPO_URL}"
    unzip -o /tmp/cloudflared.zip -d /tmp/cloudflared_temp
    mv /tmp/cloudflared_temp/cloudflared "${CLOUDFLARED_PATH}"
    chmod +x "${CLOUDFLARED_PATH}"
    rm -rf /tmp/cloudflared.zip /tmp/cloudflared_temp

    echo "Enter your Argo Tunnel domain (e.g., tunnel.example.com):"
    read -r ARGO_DOMAIN
    echo "Enter the host/server name for VMess over WebSocket (e.g., [www.visa.com](https://www.visa.com).sg):"
    read -r VMESS_WS_HOST
    echo "Enter your Argo Tunnel token:"
    read -r ARGO_TOKEN

    mkdir -p /etc/cloudflared
    echo "url: http://localhost:${VMESS_WS_PORT}" > /etc/cloudflared/config.yml
    echo "tunnel: ${ARGO_DOMAIN}" >> /etc/cloudflared/config.yml
    echo "credentials-file: /etc/cloudflared/cert.pem" >> /etc/cloudflared/config.yml

    # Write the credential file
    cat <<EOF >/etc/cloudflared/cert.pem
${ARGO_TOKEN}
EOF
    chmod 600 /etc/cloudflared/cert.pem

    # Create systemd service for cloudflared
    cat << EOF > "/etc/systemd/system/${CLOUDFLARED_SERVICE}.service"
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_PATH} tunnel --config /etc/cloudflared/config.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    echo "Reloading systemd daemon for cloudflared..."
    systemctl daemon-reload
    echo "Enabling and starting the cloudflared service..."
    systemctl enable "${CLOUDFLARED_SERVICE}"
    systemctl start "${CLOUDFLARED_SERVICE}"
    echo "Cloudflared service status:"
    systemctl status "${CLOUDFLARED_SERVICE}"
}

# Create a multi-protocol configuration file.
create_config() {
    echo "Creating Sing-Box configuration directory..."
    mkdir -p "${CONFIG_PATH}"
    mkdir -p "${LOG_PATH}"
    touch "${LOG_PATH}/access.log"
    touch "${LOG_PATH}/error.log"

    echo "Enter your domain name (e.g., example.com):"
    read -r DOMAIN_NAME
    echo "Enter port for VLESS Reality (e.g., 443):"
    read -r VLESS_REALITY_PORT
    echo "Enter port for Hysteria 2 (e.g., 443):"
    read -r HYSTERIA2_PORT
    echo "Enter port for TUIC v5 (e.g., 443):"
    read -r TUIC_PORT
    echo "Enter port for VMess over WebSocket (e.g., 8080):"
    read -r VMESS_WS_PORT
    echo "Enter port for VLESS over WebSocket TLS (e.g., 443):"
    read -r VLESS_WS_PORT
    echo "Enter path for VLESS over WebSocket TLS (e.g., /vless):"
    read -r VLESS_WS_PATH

    echo "Generating a sample config.json file with multiple protocols..."
    cat << EOF > "${CONFIG_PATH}/config.json"
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VLESS_REALITY_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "[www.bing.com](https://www.bing.com)",
        "reality": {
          "enabled": true,
          "handshake": {
            "server_names": [
              "${REALITY_DEST_HOSTNAMES[0]}"
            ],
            "version": "1.3"
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${REALITY_SHORT_ID}"
          ],
          "fallback": {
            "server_names": [
              "${REALITY_DEST_HOSTNAMES[1]}"
            ],
            "dest": "${REALITY_DEST_HOSTNAMES[1]}:443"
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "dest_override": [
          "http",
          "tls"
        ]
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": ${HYSTERIA2_PORT},
      "users": [
        {
          "password": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN_NAME}",
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "acme": {
          "domain": "${DOMAIN_NAME}",
          "email": "root@${DOMAIN_NAME}",
          "provider": "letsencrypt"
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN_NAME}",
        "alpn": [
          "h3"
        ],
        "acme": {
          "domain": "${DOMAIN_NAME}",
          "email": "root@${DOMAIN_NAME}",
          "provider": "letsencrypt"
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": ${VMESS_WS_PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws"
      }
    },
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": ${VLESS_WS_PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${VLESS_WS_PATH}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN_NAME}",
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "acme": {
          "domain": "${DOMAIN_NAME}",
          "email": "root@${DOMAIN_NAME}",
          "provider": "letsencrypt"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "domain": "geosite:cn",
        "outbound": "block"
      },
      {
        "ip": "geoip:cn",
        "outbound": "block"
      }
    ]
  }
}
EOF
    echo "Configuration file created at ${CONFIG_PATH}/config.json."
    echo "Remember to check the configuration and adjust ports or settings if needed."
}

# Generate and print sharing links.
generate_share_links() {
    echo ""
    echo "--- Sharing Links ---"
    
    # VLESS Reality
    VLESS_REALITY_SHARE_LINK="vless://${UUID}@${DOMAIN_NAME}:${VLESS_REALITY_PORT}?security=reality&encryption=none&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_DEST_HOSTNAMES[0]}&sid=${REALITY_SHORT_ID}#VLESS-Reality-${DOMAIN_NAME}"
    echo "VLESS Reality: ${VLESS_REALITY_SHARE_LINK}"
    
    # Hysteria 2
    HYSTERIA2_SHARE_LINK="hysteria2://${UUID}@${DOMAIN_NAME}:${HYSTERIA2_PORT}?insecure=1&upmbps=100&downmbps=100#Hysteria2-${DOMAIN_NAME}"
    echo "Hysteria 2: ${HYSTERIA2_SHARE_LINK}"
    
    # TUIC v5
    TUIC_SHARE_LINK="tuic://${UUID}:${UUID}@${DOMAIN_NAME}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&zero_rtt_handshake=false&disable_sni=true&alpn=h3#TUIC-V5-${DOMAIN_NAME}"
    echo "TUIC v5: ${TUIC_SHARE_LINK}"

    # VMess WebSocket
    VMESS_WS_CONFIG=$(jq -n --arg name "VMess-WS-${ARGO_DOMAIN}" --arg host "${VMESS_WS_HOST}" --arg port "443" --arg uuid "$UUID" '{
        "v": "2",
        "ps": $name,
        "add": $host,
        "port": $port,
        "id": $uuid,
        "aid": "0",
        "net": "ws",
        "type": "none",
        "host": $host,
        "path": "/",
        "tls": "tls"
    }')
    VMESS_WS_BASE64=$(echo -n "${VMESS_WS_CONFIG}" | base64 | tr -d '\n' | tr -d ' ' | tr -d '\r')
    VMESS_WS_SHARE_LINK="vmess://${VMESS_WS_BASE64}"
    echo "VMess WS: ${VMESS_WS_SHARE_LINK}"

    # VLESS WS TLS
    VLESS_WS_TLS_SHARE_LINK="vless://${UUID}@${DOMAIN_NAME}:${VLESS_WS_PORT}?security=tls&encryption=none&type=ws&host=${DOMAIN_NAME}&path=${VLESS_WS_PATH}#VLESS-WS-${DOMAIN_NAME}"
    echo "VLESS WS TLS: ${VLESS_WS_TLS_SHARE_LINK}"
}

# Generate and print subscription link.
generate_subscription_link() {
    # Generate an array of share links
    SHARE_LINKS_ARRAY=(
        "vless://${UUID}@${DOMAIN_NAME}:${VLESS_REALITY_PORT}?security=reality&encryption=none&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_DEST_HOSTNAMES[0]}&sid=${REALITY_SHORT_ID}#VLESS-Reality-${DOMAIN_NAME}"
        "hysteria2://${UUID}@${DOMAIN_NAME}:${HYSTERIA2_PORT}?insecure=1&upmbps=100&downmbps=100#Hysteria2-${DOMAIN_NAME}"
        "tuic://${UUID}:${UUID}@${DOMAIN_NAME}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&zero_rtt_handshake=false&disable_sni=true&alpn=h3#TUIC-V5-${DOMAIN_NAME}"
        "vmess://${VMESS_WS_BASE64}"
        "vless://${UUID}@${DOMAIN_NAME}:${VLESS_WS_PORT}?security=tls&encryption=none&type=ws&host=${DOMAIN_NAME}&path=${VLESS_WS_PATH}#VLESS-WS-${DOMAIN_NAME}"
    )

    # Join the links with newlines and Base64 encode them
    SUBSCRIPTION_CONTENT=$(printf "%s\n" "${SHARE_LINKS_ARRAY[@]}")
    SUBSCRIPTION_BASE64=$(echo -n "${SUBSCRIPTION_CONTENT}" | base64 | tr -d '\n' | tr -d ' ' | tr -d '\r')
    
    # Create a temporary web server to serve the subscription link
    echo "Creating a temporary subscription URL..."
    cat << EOF > "${CONFIG_PATH}/index.html"
<!DOCTYPE html>
<html>
<head>
    <title>Sing-Box Subscription</title>
</head>
<body>
    <pre>${SUBSCRIPTION_CONTENT}</pre>
</body>
</html>
EOF

    echo "--- Subscription Link ---"
    echo "You can host a file with the following Base64 content to create a subscription link:"
    echo "${SUBSCRIPTION_BASE64}"
    echo ""
    echo "Alternatively, you can create a simple web server to serve the links, or paste the links directly into your client."
}

# Create a systemd service file.
create_service() {
    echo "Creating systemd service file for Sing-Box..."
    cat << EOF > "/etc/systemd/system/${SERVICE_NAME}.service"
[Unit]
Description=Sing-Box Service
Documentation=[https://sing-box.sagernet.org/](https://sing-box.sagernet.org/)
After=network.target nss-lookup.target

[Service]
Type=exec
User=root
WorkingDirectory=${CONFIG_PATH}
ExecStart=${INSTALL_PATH}/sing-box run -c ${CONFIG_PATH}/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    echo "Reloading systemd daemon..."
    systemctl daemon-reload

    echo "Enabling and starting the Sing-Box service..."
    systemctl enable "${SERVICE_NAME}"
    systemctl start "${SERVICE_NAME}"

    echo "Sing-Box service status:"
    systemctl status "${SERVICE_NAME}"
}

# Uninstalls the script and all associated files/services.
uninstall_script() {
    read -p "Are you sure you want to uninstall Sing-Box and Cloudflare Tunnel? This will delete all files and services. (y/n): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Uninstallation cancelled."
        exit 1
    fi

    echo "Stopping and disabling services..."
    systemctl stop "${SERVICE_NAME}"
    systemctl disable "${SERVICE_NAME}"
    systemctl stop "${CLOUDFLARED_SERVICE}" >/dev/null 2>&1
    systemctl disable "${CLOUDFLARED_SERVICE}" >/dev/null 2>&1

    echo "Removing service files..."
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "/etc/systemd/system/${CLOUDFLARED_SERVICE}.service" >/dev/null 2>&1
    systemctl daemon-reload

    echo "Removing binaries and configuration files..."
    rm -f "${INSTALL_PATH}/sing-box"
    rm -f "${CLOUDFLARED_PATH}" >/dev/null 2>&1
    rm -rf "${CONFIG_PATH}"
    rm -rf "/etc/cloudflared"

    echo "Uninstallation complete. All files and services have been removed."
}


# --- Main script execution ---
check_root

echo "Choose an option:"
echo "1) Install Sing-Box and configure services"
echo "2) Uninstall Sing-Box and all associated files"
read -p "Enter your choice (1 or 2): " -r choice

if [[ "${choice}" == "1" ]]; then
    install_dependencies
    install_singbox
    generate_keys
    echo "Do you want to use Cloudflare Argo Tunnel for VMess over WebSocket? (y/n)"
    read -r use_argo_tunnel

    if [[ "${use_argo_tunnel}" =~ ^[Yy]$ ]]; then
        install_argo
    fi

    create_config
    generate_share_links
    generate_subscription_link
    create_service
    echo ""
    echo "Sing-Box installation and configuration is complete!"
    echo "Please verify the configuration file and make sure your firewall allows traffic on the configured ports."
    echo "If you need to change the configuration, edit ${CONFIG_PATH}/config.json and then restart the service with 'sudo systemctl restart ${SERVICE_NAME}'."
elif [[ "${choice}" == "2" ]]; then
    uninstall_script
else
    echo "Invalid choice. Please enter '1' or '2'."
fi
