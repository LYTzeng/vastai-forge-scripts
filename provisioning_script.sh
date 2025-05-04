#!/bin/bash

# modified based on: https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/derivatives/pytorch/derivatives/sd-forge/provisioning_scripts/default.sh

# === [ Load config + env from GitHub Gist ] ===
CONFIG_DIR="/tmp/provisioning"
CONFIG_SCRIPT_URL="https://github.com/LYTzeng/vastai-forge-scripts/generate_vast_env.sh"

mkdir -p "$CONFIG_DIR"
curl -fsSL "$CONFIG_SCRIPT_URL" -o "$CONFIG_DIR/generate_vast_env.sh"
chmod +x "$CONFIG_DIR/generate_vast_env.sh"

if [[ -n $CONFIG_YAML_URL ]]; then
    curl -fsSL "$CONFIG_YAML_URL" -o "$CONFIG_DIR/forge_sync_config.yaml"
    # Import Bash arrays and FORGE_COMMIT
    eval "$("$CONFIG_DIR/generate_vast_env.sh" "$CONFIG_DIR/forge_sync_config.yaml")"
else
    echo '\n\033[31m🚨 CONFIG_YAML_URL is empty. Models and extensions will not be downloaded. 🚨\033[0m'
fi


source /venv/main/bin/activate
FORGE_DIR=${WORKSPACE}/stable-diffusion-webui-forge

APT_PACKAGES=( )
PIP_PACKAGES=( )

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ### yeah, i am ;)

SUPERVISORD_CONF_DIR='/etc/supervisor/conf.d'

function provisioning_start() {
    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_pip_packages
    provisioning_install_filebrowser
    provisioning_get_extensions
    provisioning_has_valid_hf_token
    provisioning_has_valid_civitai_token

    provisioning_get_files "${FORGE_DIR}/models/Lora" "${LORA_MODELS[@]}"
    provisioning_get_files "${FORGE_DIR}/models/ESRGAN" "${ESRGAN_MODELS[@]}"
    provisioning_get_files "${FORGE_DIR}/models/VAE" "${VAE_MODELS[@]}"
    provisioning_get_files "${FORGE_DIR}/models/ControlNet" "${CONTROLNET_MODELS[@]}"
    provisioning_get_files "${FORGE_DIR}/models/UNet" "${UNET_MODELS[@]}"
    mkdir "${FORGE_DIR}/models/adetailer"
    provisioning_get_files "${FORGE_DIR}/models/adetailer" "${ADETAILER_MODELS[@]}"
    provisioning_get_files "${FORGE_DIR}/models/Stable-diffusion" "${CHECKPOINT_MODELS[@]}"

    # Avoid git errors because we run as root but files are owned by 'user'
    export GIT_CONFIG_GLOBAL=/tmp/temporary-git-config
    git config --file $GIT_CONFIG_GLOBAL --add safe.directory '*'

    if [[ -n $FORGE_COMMIT ]]; then
        echo "Switching Forge to commit $FORGE_COMMIT"
        cd "$FORGE_DIR"
        git checkout main
        git fetch
        git checkout $FORGE_COMMIT

        # Reinstall dependencies
        pip install -r requirements-versions.txt

        cd $WORKSPACE
    fi

    # Start and exit because webui will probably require a restart
    cd "${FORGE_DIR}"
    LD_PRELOAD=libtcmalloc_minimal.so.4 \
        python launch.py \
            --skip-python-version-check \
            --no-download-sd-model \
            --do-not-download-clip \
            --no-half \
            --port 11404 \
            --exit

    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if [[ -n $APT_PACKAGES ]]; then
        sudo $APT_INSTALL "${APT_PACKAGES[@]}"
    fi
}

function provisioning_get_pip_packages() {
    if [[ -n $PIP_PACKAGES ]]; then
        pip install --no-cache-dir "${PIP_PACKAGES[@]}"
    fi
}

function provisioning_install_filebrowser(){
    echo 'Installing File Browser...'
    config_dir=/etc/filebrowser/conf.db
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
    mkdir -p $FORGE_DIR/outputs
    filebrowser config init -d $config_dir --auth.method=noauth -p=3000 -a=0.0.0.0 --root $FORGE_DIR/outputs --baseurl "" --lockPassword --perm.admin="true" --perm.create="true" --perm.delete="true" --perm.execute="true" --perm.modify="true" --perm.rename="true" --signup="false"
    filebrowser users add admin '' -d $config_dir
    cat > $SUPERVISORD_CONF_DIR/filebrowser.conf << UWU
[program:filebrowser]
environment=PROC_NAME="%(program_name)s"
command=filebrowser -d $config_dir
autostart=true
autorestart=true
exitcodes=0
startsecs=0
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=10
# This is necessary for Vast logging to work alongside the Portal logs (Must output to /dev/stdout)
stdout_logfile=/dev/stdout
redirect_stderr=true
stdout_events_enabled=true
stdout_logfile_maxbytes=0
stdout_logfile_backups=0
UWU
}

function provisioning_get_extensions() {
    for repo in "${EXTENSIONS[@]}"; do
        dir="$(basename "${repo%.git}")"
        path="${FORGE_DIR}/extensions/${dir}"
        if [[ ! -d $path ]]; then
            printf "Downloading extension: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
        fi
    done
}

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 1; fi

    dir="$1"
    mkdir -p "$dir"
    shift
    arr=("$@")
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_has_valid_hf_token() {
    [[ -z "$HF_TOKEN" ]] && return 0  # No token? Skip check

    url="https://huggingface.co/api/whoami-v2"
    response=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json")

    if [[ "$response" -eq 200 ]]; then
        echo "[✓] Hugging Face token valid."
        return 0
    fi

    # Loop forever and log
    while true; do
        echo -e "\n\033[31m🚨 INVALID Hugging Face TOKEN 🚨\033[0m"
        echo "HTTP Status: $response"
        echo "HF_TOKEN was provided but failed validation. Check your environment variable."
        echo "------------------------------------------------------------"
        echo "🐢 The script is paused to keep this log visible..."
        sleep 15
    done
}

function provisioning_has_valid_civitai_token() {
    [[ -z "$CIVITAI_TOKEN" ]] && return 0  # No token? Skip check

    url="https://civitai.com/api/v1/models?hidden=1&limit=1"
    response=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")

    if [[ "$response" -eq 200 ]]; then
        echo "[✓] Civitai token valid."
        return 0
    fi

    # Loop forever and log
    while true; do
        echo -e "\n\033[31m🚨 INVALID CIVITAI TOKEN 🚨\033[0m"
        echo "HTTP Status: $response"
        echo "CIVITAI_TOKEN was provided but failed validation. Check your environment variable."
        echo "------------------------------------------------------------"
        echo "🛑 The script is paused to keep this log visible in Vast UI..."
        sleep 15
    done
}

function provisioning_download() {
    local url="$1"
    local target="$2"
    local auth_token=""

    if [[ -n $HF_TOKEN && $url =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif [[ -n $CIVITAI_TOKEN && $url =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi

    mkdir -p "$target"

    if [[ -n $auth_token ]]; then
        (cd "$target" && curl -LJO -H "Authorization: Bearer $auth_token" "$url")
    else
        (cd "$target" && curl -LJO "$url")
    fi
}

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete: Application will start now\n\n"
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
    supervisorctl reread
    supervisorctl reload
fi
