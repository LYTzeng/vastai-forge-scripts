#!/bin/bash

# === EDIT THIS: local target directory ===
LOCAL_DIR="/mnt/d/stable_diffusion/outputs"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <REMOTE_IP> <SSH_PORT>"
    exit 1
fi

REMOTE_IP="$1"
SSH_PORT="$2"

# Run rsync
rsync -avz -e "ssh -p $SSH_PORT" root@"$REMOTE_IP":/workspace/stable-diffusion-webui-forge/outputs/ "$LOCAL_DIR"/
