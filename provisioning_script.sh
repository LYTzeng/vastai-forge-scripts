#!/bin/bash

# modified based on: https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/derivatives/pytorch/derivatives/sd-forge/provisioning_scripts/default.sh

# === [ Load config + env from GitHub Gist ] ===
CONFIG_DIR="/tmp/provisioning"
CONFIG_SCRIPT_URL="https://raw.githubusercontent.com/LYTzeng/vastai-forge-scripts/refs/heads/mainline/generate_vast_env.sh"

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

    cd "$FORGE_DIR"
    git remote add reForge https://github.com/Panchovix/stable-diffusion-webui-reForge
    git branch Panchovix/main
    git checkout Panchovix/main
    git fetch reForge 
    if [[ -n $FORGE_COMMIT ]]; then
        echo "Switching Forge to reForge on commit $FORGE_COMMIT..."
        git checkout $FORGE_COMMIT
        git pull

    else
        echo "Switching Forge to reForge..."
        git branch -u reForge/main
        git stash
        git pull
    fi
    # Reinstall dependencies
    pip install -r requirements_versions.txt
    cd $WORKSPACE

    # reForge clones Stability-AI/stablediffusion at launch, but that repo was deleted from
    # GitHub (2026-10: "fatal: could not read Username" = 404 -> Forge never starts).
    # Pin a fork that still carries the exact commit reForge expects (cf1d67a6). Export for
    # this launch and persist for the supervisor-started Forge via the venv activate hook.
    export STABLE_DIFFUSION_REPO="${STABLE_DIFFUSION_REPO:-https://github.com/w-e-w/stablediffusion.git}"
    echo "export STABLE_DIFFUSION_REPO=\"$STABLE_DIFFUSION_REPO\"" >> /venv/main/bin/activate
    echo "export GIT_TERMINAL_PROMPT=0" >> /venv/main/bin/activate

    provisioning_apply_forge_settings

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

function provisioning_apply_forge_settings() {
    # Settings > Extra Networks > "When adding to prompt, refer to Lora by": default is
    # "Alias from file", which makes <lora:...> tags use the metadata alias instead of the
    # filename, so saved prompts/EXIF written with filenames stop matching after a fresh
    # install. Pre-seed config.json (merged, so anything already there is kept).
    local cfg="${FORGE_DIR}/config.json"
    echo "Applying Forge settings to ${cfg}..."
    FORGE_CONFIG_JSON="$cfg" python - << 'PY'
import json, os
path = os.environ["FORGE_CONFIG_JSON"]
try:
    with open(path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
cfg.update({
    "lora_preferred_name": "Filename",
})
with open(path, "w") as f:
    json.dump(cfg, f, indent=4)
print("  lora_preferred_name = Filename")
PY
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
    # filebrowser >= 2.32 rejects passwords under 12 chars even with --auth.method=noauth
    # (seen: "Error: password is too short, minimum length is 12"), which left no user and
    # a dead File Browser. noauth never checks the password, so any 12+ char value works.
    filebrowser users add admin "$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)" -d $config_dir
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

# --- download engine (begin) ---
# Parallel model downloads. Each URL is fetched by a background job (DOWNLOAD_JOBS at a
# time) into a private temp dir under the target, then moved into place: jobs never
# collide and a partial file from a failed attempt is never left behind. HF/Civitai cap a
# single connection at ~70-100 MB/s while the host link is several Gbps (measured
# 2026-10-20: 6.8 GB in 66-94 s each), so the checkpoints finish together instead of
# one after another.
#
# Per-file curl output (progress meter, warnings) goes to $PROVISIONING_DL_LOGS/<batch>/<n>.curl.
# The main log gets one line per file; useful_scripts/vast_provision_watch.py parses these:
#   Downloading: <url>                                        job started
#   [OK] <saved filename> | <MB> MB in <s>s (<MB/s> MB/s) | <url>
#   [FAIL] <url> | curl exit <n> | <last curl message>        (or "| tiny body ..." = error page)
#   [retry] <url> | curl exit <n> on attempt <k>, retrying    (e.g. connection reset)
#   [dl] <done>/<total> done | <label> <pct>% <received>/<total> <speed>/s | ...
#        progress tick every DOWNLOAD_TICK_SECS while jobs are in flight
#   Downloads to <dir>: <ok>/<total> ok, <failed> failed
DOWNLOAD_JOBS=${DOWNLOAD_JOBS:-4}
DOWNLOAD_TICK_SECS=${DOWNLOAD_TICK_SECS:-30}
PROVISIONING_DL_LOGS=${PROVISIONING_DL_LOGS:-/tmp/provisioning/dl-logs}
PROVISIONING_DL_OK=0
PROVISIONING_DL_FAIL=0

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 1; fi
    local dir="$1"; shift
    local -a arr=("$@") pids=()
    local n=${#arr[@]} batch label launched=0 finished=0 last_tick=$SECONDS i ok fail
    mkdir -p "$dir" "$PROVISIONING_DL_LOGS"
    batch=$(mktemp -d "${PROVISIONING_DL_LOGS}/batch.XXXXXX")
    printf "Downloading %s model(s) to %s (%s at a time)...\n" "$n" "$dir" "$DOWNLOAD_JOBS"
    while (( finished < n )); do
        while (( launched < n && launched - finished < DOWNLOAD_JOBS )); do
            label=${arr[launched]##*/}; label=${label%%\?*}
            printf '%s' "$label" > "${batch}/${launched}.label"
            printf "Downloading: %s\n" "${arr[launched]}"
            provisioning_download_job "${arr[launched]}" "$dir" "${batch}/${launched}" &
            pids[launched]=$!
            launched=$((launched + 1))
        done
        sleep 1
        # A job that died without writing its result must not stall the batch forever.
        for (( i = 0; i < launched; i++ )); do
            [[ -e ${batch}/${i}.result ]] && continue
            if ! kill -0 "${pids[i]}" 2>/dev/null && [[ ! -e ${batch}/${i}.result ]]; then
                printf '[FAIL] %s | download job died without a result\n' "${arr[i]}"
                echo "FAIL ${arr[i]}" > "${batch}/${i}.result"
            fi
        done
        finished=$(find "$batch" -maxdepth 1 -name '*.result' | wc -l)
        if (( finished < n && SECONDS - last_tick >= DOWNLOAD_TICK_SECS )); then
            provisioning_download_tick "$batch" "$finished" "$n"
            last_tick=$SECONDS
        fi
    done
    wait
    ok=$(cat "$batch"/*.result | grep -c '^OK ')
    fail=$((n - ok))
    PROVISIONING_DL_OK=$((PROVISIONING_DL_OK + ok))
    PROVISIONING_DL_FAIL=$((PROVISIONING_DL_FAIL + fail))
    printf "Downloads to %s: %s/%s ok, %s failed\n\n" "$dir" "$ok" "$n" "$fail"
}

# One background job: fetch into a private scratch dir, validate, decode the name, move into place.
function provisioning_download_job() {
    local url="$1" target="$2" slot="$3"
    local tmp t0=$SECONDS rc f name bytes=0 secs mb why
    tmp=$(mktemp -d "${target}/.dl.XXXXXX") || {
        printf '[FAIL] %s | cannot create scratch dir in %s\n' "$url" "$target"
        echo "FAIL $url" > "${slot}.result"; return 1; }
    provisioning_download "$url" "$tmp" "${slot}.curl"
    rc=$?
    f=$(find "$tmp" -maxdepth 1 -type f | head -n1)
    [[ -n $f ]] && bytes=$(stat -c %s -- "$f")
    if (( rc == 0 && bytes >= 4096 )); then
        provisioning_decode_filenames "$tmp"
        f=$(find "$tmp" -maxdepth 1 -type f | head -n1); name=${f##*/}
        mv -f -- "$f" "${target}/${name}"
        secs=$((SECONDS - t0)); (( secs > 0 )) || secs=1
        mb=$(( (bytes + 999999) / 1000000 ))
        printf '[OK] %s | %s MB in %ss (%s MB/s) | %s\n' "$name" "$mb" "$secs" "$((mb / secs))" "$url"
        echo "OK $name" > "${slot}.result"
    else
        if (( rc != 0 )); then
            why="curl exit $rc | $(grep -oE 'curl: \([0-9]+\).*' "${slot}.curl" 2>/dev/null | tail -n1)"
        else
            why="tiny body ($bytes bytes) - an error page, not a model"
        fi
        printf '[FAIL] %s | %s\n' "$url" "$why"
        echo "FAIL $url" > "${slot}.result"
    fi
    rm -rf -- "$tmp"
}

# Fetch one URL into $scratch, a PRIVATE directory (it is emptied between attempts).
# curl's progress meter and messages go to $errlog (default: stderr).
function provisioning_download() {
    local url="$1" scratch="$2" errlog="${3:-/dev/stderr}"
    local -a auth=()
    if [[ -n ${HF_TOKEN:-} && $url =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth=(-H "Authorization: Bearer $HF_TOKEN")
    elif [[ -n ${CIVITAI_TOKEN:-} && $url =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth=(-H "Authorization: Bearer $CIVITAI_TOKEN")
    fi
    mkdir -p "$scratch"
    # -f: an HTTP error (403/404) is a failure, not an error page saved as a "model".
    # --retry: curl itself retries timeouts and 408/429/5xx.
    # --speed-limit/--speed-time: abort below 50 KB/s for 60 s (stalled host); that counts
    #   as a timeout, so it is retried instead of hanging the whole provisioning run.
    #   It only watches the BODY: a server that accepts the connection and sends no headers
    #   is not caught (seen: HF held a request 134 s before answering 404), hence
    # --connect-timeout/--max-time as hard backstops (6.8 GB needs 5.7 MB/s to make 20 min).
    # Outer loop: re-run for errors curl does not retry on its own (seen: curl (56)
    #   connection reset by peer from Civitai), but not for HTTP errors (exit 22):
    #   a dead URL stays dead and should fail fast.
    local -a curl_opts=(-fLJO --retry 3 --retry-delay 10 --speed-limit 51200 --speed-time 60
                        --connect-timeout 30 --max-time 1200 --stderr "$errlog")
    local attempt rc
    for attempt in 1 2 3; do
        # body goes to the file (-O); stdout only carries notices like "Saved to filename"
        (cd "$scratch" && curl "${curl_opts[@]}" "${auth[@]}" "$url" >/dev/null)
        rc=$?
        (( rc == 0 || rc == 22 || attempt == 3 )) && break
        rm -f -- "$scratch"/*   # a partial file would make -J refuse to overwrite
        printf '[retry] %s | curl exit %s on attempt %s, retrying in 10 s\n' "$url" "$rc" "$attempt"
        sleep 10
    done
    return $rc
}

# curl -LJO keeps percent-escapes from Content-Disposition verbatim, e.g. HF serves
# "kazukoai-illust-kanav3(1).safetensors" as "...kanav3%281%29.safetensors", so saved
# prompts/EXIF referencing <lora:kazukoai-illust-kanav3(1):1> would not match.
# Decode %XX sequences in the file names inside $dir.
function provisioning_decode_filenames() {
    local dir="$1" f decoded
    for f in "$dir"/*%[0-9A-Fa-f][0-9A-Fa-f]*; do
        [[ -e "$f" ]] || continue
        decoded="$(printf '%b' "${f//%/\\x}")"
        [[ "$decoded" != "$f" && ! -e "$decoded" ]] && mv -- "$f" "$decoded"
    done
}

# One progress line for the files still in flight, read from their curl meters.
function provisioning_download_tick() {
    local batch="$1" finished="$2" total="$3" log slot line
    line="[dl] ${finished}/${total} done"
    for log in "$batch"/*.curl; do
        [[ -e $log ]] || continue
        slot=${log%.curl}
        [[ -e ${slot}.result ]] && continue
        line+=" | $(cat "${slot}.label" 2>/dev/null) $(tr '\r' '\n' < "$log" | awk '
            NF == 12 && $1 ~ /^[0-9]+$/ { l = $0 }
            END { if (l == "") print "connecting";
                  else { split(l, a, " "); printf "%s%% %s/%s %s/s", a[3], a[4], a[2], a[12] } }')"
    done
    printf '%s\n' "$line"
}
# --- download engine (end) ---

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

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nDownloads total: %s ok, %s failed\n" "$PROVISIONING_DL_OK" "$PROVISIONING_DL_FAIL"
    printf "\nProvisioning complete: Application will start now\n\n"
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
    supervisorctl reread
    supervisorctl reload
fi
