#!/bin/bash

# =========================================
# Ritual Network Infernet Auto Installer - FIXED
# =========================================

# Function to display logo
display_logo() {
  sleep 2
  curl -s https://raw.githubusercontent.com/0xtnpxsgt/logo/refs/heads/main/logo.sh | bash
  sleep 1
}

# Function to display menu
display_menu() {
  clear
  display_logo
  echo "===================================================="
  echo "     RITUAL NETWORK INFERNET AUTO INSTALLER         "
  echo "===================================================="
  echo ""
  echo "Please select an option:"
  echo "1) Install Ritual Network Infernet"
  echo "2) Uninstall Ritual Network Infernet"
  echo "3) Exit"
  echo ""
  echo "===================================================="
  read -p "Enter your choice (1-3): " choice
}

# Function to restart Docker containers
restart_docker_containers() {
  echo "Ensuring all containers are down before restart..."
  cd ~/infernet-container-starter
  docker compose -f deploy/docker-compose.yaml down

  echo "Removing any remaining containers..."
  docker rm -f infernet-fluentbit infernet-redis infernet-anvil infernet-node 2>/dev/null || true

  echo "Starting Docker containers..."
  docker compose -f deploy/docker-compose.yaml up -d
}

# Function to install Ritual Network Infernet
install_ritual() {
  clear
  display_logo
  echo "===================================================="
  echo "     INSTALLING RITUAL NETWORK INFERNET             "
  echo "===================================================="
  echo ""

  echo "Please enter your private key (with 0x prefix if needed)"
  echo "Note: Input will be hidden for security"
  read -s private_key
  echo "Private key received (hidden for security)"

  if [[ ! $private_key =~ ^0x ]]; then
    private_key="0x$private_key"
    echo "Added 0x prefix to private key"
  fi

  echo "Installing dependencies..."
  sudo apt update && sudo apt upgrade -y
  sudo apt -qy install curl git jq lz4 build-essential screen docker.io docker-compose

  sudo usermod -aG docker $USER

  echo "Cloning repository..."
  git clone https://github.com/ritual-net/infernet-container-starter || true
  cd infernet-container-starter

  echo "Creating configuration files..."

  cat > ~/infernet-container-starter/deploy/config.json << EOL
{
    "log_path": "infernet_node.log",
    "server": { "port": 4000, "rate_limit": { "num_requests": 100, "period": 100 } },
    "chain": {
        "enabled": true,
        "trail_head_blocks": 3,
        "rpc_url": "https://mainnet.base.org/",
        "registry_address": "0x3B1554f346DFe5c482Bb4BA31b880c1C18412170",
        "wallet": { "max_gas_limit": 4000000, "private_key": "$private_key", "allowed_sim_errors": [] },
        "snapshot_sync": { "sleep": 3, "batch_size": 10000, "starting_sub_id": 180000, "sync_period": 30 }
    },
    "startup_wait": 1.0,
    "redis": { "host": "redis", "port": 6379 },
    "forward_stats": true,
    "containers": [{ "id": "hello-world", "image": "ritualnetwork/hello-world-infernet:latest", "external": true, "port": "3000", "allowed_delegate_addresses": [], "allowed_addresses": [], "allowed_ips": [], "command": "--bind=0.0.0.0:3000 --workers=2", "env": {}, "volumes": [], "accepted_payments": {}, "generates_proofs": false }]
}
EOL

  cp ~/infernet-container-starter/deploy/config.json ~/infernet-container-starter/projects/hello-world/container/config.json

  echo "Restarting Docker containers..."
  restart_docker_containers

  echo "Please logout and login again to apply Docker group permissions."
  echo "Then rerun this installer to continue."
  read -n 1 -s -r -p "Press any key to exit..."
  exit 0
}

# Function to uninstall Ritual Network Infernet
uninstall_ritual() {
  clear
  display_logo
  echo "===================================================="
  echo "     UNINSTALLING RITUAL NETWORK INFERNET           "
  echo "===================================================="
  echo ""

  read -p "Are you sure you want to uninstall? (y/n): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Uninstallation cancelled."
    read -n 1 -s -r -p "Press any key to return to menu..."
    return
  fi

  echo "Stopping and removing Docker containers..."
  docker compose -f ~/infernet-container-starter/deploy/docker-compose.yaml down 2>/dev/null
  docker rm -f infernet-fluentbit infernet-redis infernet-anvil infernet-node 2>/dev/null || true

  echo "Removing installation files..."
  rm -rf ~/infernet-container-starter ~/foundry ~/ritual-service.sh ~/ritual-deployment.log ~/ritual-service.log

  echo "Cleaning up Docker resources..."
  docker system prune -f

  echo "===================================================="
  echo "   RITUAL NETWORK INFERNET UNINSTALLATION COMPLETE  "
  echo "===================================================="
  echo ""
  read -n 1 -s -r -p "Press any key to return to menu..."
}

# Main program
main() {
  while true; do
    display_menu

    case $choice in
      1)
        install_ritual
        ;;
      2)
        uninstall_ritual
        ;;
      3)
        clear
        display_logo
        echo "Thank you for using the Ritual Network Infernet Auto Installer!"
        echo "Exiting..."
        exit 0
        ;;
      *)
        echo "Invalid option. Press any key to try again..."
        read -n 1 -s -r
        ;;
    esac
  done
}

main
