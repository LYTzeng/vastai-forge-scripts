#!/bin/bash

REMOTE_DIR="/workspace/stable-diffusion-webui-forge/models/Lora"

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <REMOTE_IP> <SSH_PORT> <LOCAL_LORA_FILE_PATH>"
    exit 1
fi

REMOTE_IP="$1"
SSH_PORT="$2"
LOCAL_LORA="$3"

rsync -avz -e "ssh -p $SSH_PORT" "$LOCAL_LORA" root@"$REMOTE_IP":"$REMOTE_DIR"/
