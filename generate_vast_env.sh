#!/bin/bash
set -e

CONFIG_FILE="${1:-./forge_sync_config.yaml}"

EXTENSIONS=()
CHECKPOINT_MODELS=()
LORA_MODELS=()
ESRGAN_MODELS=()
VAE_MODELS=()
UNET_MODELS=()
CONTROLNET_MODELS=()
ADETAILER_URLS=()
FORGE_COMMIT=""

SECTION=""

while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

  if [[ "$line" =~ ^([a-zA-Z0-9_]+):$ ]]; then
    SECTION="${BASH_REMATCH[1]}"
    continue
  fi

  if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.*)$ ]]; then
    item="${BASH_REMATCH[1]}"
    case "$SECTION" in
      extensions)     EXTENSIONS+=("$item") ;;
      models)         CHECKPOINT_MODELS+=("$item") ;;
      loras)          LORA_MODELS+=("$item") ;;
      esrgan)         ESRGAN_MODELS+=("$item") ;;
      vae)            VAE_MODELS+=("$item") ;;
      unet)           UNET_MODELS+=("$item") ;;
      controlnet)     CONTROLNET_MODELS+=("$item") ;;
      adetailer)      ADETAILER_MODELS+=("$item") ;;
    esac
  fi

  if [[ "$SECTION" == "forge" && "$line" =~ ^[[:space:]]*commit:[[:space:]]*(.*)$ ]]; then
    FORGE_COMMIT="${BASH_REMATCH[1]}"
  fi
done < "$CONFIG_FILE"

# Export all as Bash arrays or variables
declare -p \
  EXTENSIONS \
  CHECKPOINT_MODELS \
  LORA_MODELS \
  ESRGAN_MODELS \
  VAE_MODELS \
  UNET_MODELS \
  CONTROLNET_MODELS \
  ADETAILER_MODELS

echo "declare -x FORGE_COMMIT=\"$FORGE_COMMIT\""
