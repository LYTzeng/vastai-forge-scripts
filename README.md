# Vast.ai Provisioning Script for Stable Diffusion Forge UI

This repository provides a modified [provisioning script](https://github.com/vast-ai/base-image/blob/main/derivatives/pytorch/derivatives/sd-forge/provisioning_scripts/default.sh) for running [**Stable Diffusion Web UI Forge**](https://hub.docker.com/r/vastai/sd-forge/) Template on [Vast.ai](https://vast.ai). 

---

## Features

- Enhance the original provisioning script which has some unfinished or unused functions.
- Deploys Stable Diffusion WebUI Forge with custom extensions, models, LoRAs, and upscalers. Which IMO has a better solution compared to the original provisioning script.
- Pulls config from a remote YAML file (no bloated env vars)
- Supports Hugging Face and Civitai Bearer tokens
- Git checkout to a specific Forge commit (via YAML)
- Safe re-runs (resumes downloads, skips reinstallation)
- Logs invalid token warnings repeatedly to help visibility in Vast's web UI (easier to see them on Instance Portal)

---

## Files

- `provisioning.sh`  
  Main script used by Vast.ai container provisioning. Downloads and applies your config.

- `generate_vast_env.sh`  
  Parses the remote YAML config and outputs Bash arrays for models, extensions, etc.

- `forge_sync_config.yaml`  
  The actual configuration file listing all your URLs and Forge commit.

---

## How to Use

1. Fork this repo or copy the scripts into your own repo or Gist.
2. Host your `forge_sync_config.yaml` and `generate_vast_env.sh` on GitHub Gist or anywhere accessible via HTTPS.
3. change the below variables in `provisioning.sh`:
    - `CONFIG_YAML_URL` should be pointing to your `forge_sync_config.yaml` in your forked repository.
    - `CONFIG_SCRIPT_URL` can remain unchanged if you don't need customizations. Or point to your `generate_vast_env.sh`
4. Edit `forge_sync_config.yaml` to configure the models you need to download when starting a Vast.ai instance.
5. In Vast.ai, click "Edit" under the Template [**Stable Diffusion Web UI Forge**](https://hub.docker.com/r/vastai/sd-forge/) . After finish below changes, click save. This allows you to keep your configurations such as environment variables.
6. use the raw URL of `provisioning.sh` as your provisioning script.
7. Configure `HF_TOKEN` and `CIVITAI_TOKEN` as environment variables in Vast Template settings. This allows you to dwnload your private models. <mark>For security, remember to keep the Template private since it contains your tokens.</mark>
8. The script will fetch the YAML + parser script and install everything for you.

---

## Sample `forge_sync_config.yaml`

```yaml
forge:
  commit: e53cf13e

extensions:
  - https://github.com/Bing-su/adetailer.git
  - https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git

models:
  - https://civitai.com/api/download/models/1234567

loras:
  - https://huggingface.co/youruser/lora1.safetensors

adetailer:
  - https://huggingface.co/user/adetailer/resolve/main/body.safetensors

esrgan:
  - https://huggingface.co/cszn/ESRGAN/resolve/main/4x-AnimeSharp.pth
```

---

## Tips

- Put your models/loras/upscalers on Hugging Face or Civitai when possible
- Use `rsync` separately to push private models from your local machine if needed
- Don't forget to pass `HF_TOKEN` and `CIVITAI_TOKEN` as environment variables in Vast

---

## Troubleshooting

- If your token is invalid, the script will pause and repeatedly log a banner message to avoid rolling log loss in Vast’s UI.
- If a file gets stuck on download, remove the partially downloaded file and try again.
- Logs from `provisioning.sh` is located at `/var/log/portal/provisioning.log`. [[ref]](`forge_sync_config.yaml`)

---

## License

As required by the original repository, must keep using Vast.ai Elastic License.
