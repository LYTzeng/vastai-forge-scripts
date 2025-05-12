# Vast.ai Provisioning Script for SD WebUI reFroge

This repository provides a modified/enhanced [provisioning script](https://github.com/vast-ai/base-image/blob/main/derivatives/pytorch/derivatives/sd-forge/provisioning_scripts/default.sh) for running [SD Web UI reforge](https://github.com/Panchovix/stable-diffusion-webui-reForge) using **[SD WebUI Forge](https://cloud.vast.ai/?ref_id=62897&creator_id=62897&name=SD%20WebUI%20Forge)** Template on [Vast.ai](https://vast.ai).

Note: This provision script will switch to reForge from the original Forge UI. So it's reForge, not Forge.

---

## Features

- Uses reForge instead of Forge UI
- Provides a better and more image-friendly file browser than original Jupyter's.
- Deploys Stable Diffusion WebUI Forge with custom extensions, models, LoRAs, and upscalers, by using a remote YAML file.
- Enhance the original provisioning script which has some unfinished or unused functions.
- Supports Hugging Face and Civitai Bearer tokens, for downloading your own private models.
- Git checkout to a specific Forge commit (via YAML)

---

## Files

- `forge_sync_config.yaml`  
  The actual configuration file listing all your model URLs for download, and specify your preferred Forge commit.
- `provisioning.sh`  
  Main script used by Vast.ai container provisioning. Downloads and applies your config.
- `generate_vast_env.sh`  
  Parses the remote YAML config and outputs Bash arrays for models, extensions, etc.

---

## How to Use

1. Edit `forge_sync_config.yaml` to configure the models you need to download when starting a Vast.ai instance. Upload your edited config to GitHub Gist or anywhere accessible via HTTPS. (See the example [here](https://github.com/LYTzeng/vastai-forge-scripts?tab=readme-ov-file#sample-forge_sync_configyaml))
2. In Vast.ai, click "Edit" (pen icon) under the Template **[SD WebUI Forge](https://cloud.vast.ai/?ref_id=62897&creator_id=62897&name=SD%20WebUI%20Forge)**. After finish below changes, click save. This allows you to keep your configurations such as environment variables.
3. Configure these environment variables in Vast Template settings:
   - Replace the URL of the environment variable `PROVISIONING_SCRIPT` with
     `https://raw.githubusercontent.com/LYTzeng/vastai-forge-scripts/refs/heads/mainline/provisioning_script.sh`
   - Replace the value of the environment variable `PORTAL_CONFIG` with the following:
      ```sh
      "localhost:1111:11111:/:Instance Portal|localhost:7860:17860:/:WebUI Forge|localhost:8080:18080:/:Jupyter|localhost:8080:18080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing|localhost:3000:3000:/:File Browser"
      ```
   - `HF_TOKEN` (Hugging Face token) and `CIVITAI_TOKEN`: This allows you to dwnload your private models. <mark>For security, remember to keep the Template private since it contains your tokens.</mark>
   - `CONFIG_YAML_URL`: specify the URL which is your `forge_sync_config.yaml`
4. Launch an instance using your saved Template.
5. Start generating waifus!! UWU
6. You can view generated images easier by using "File Browser" in [Instance Portal](https://docs.vast.ai/instance-portal).

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
- If you prefer the using Forge than reForge, do the following:
```sh
cd /workspace/stable-diffusion-webui-forge
git checkout main
# you might need to reinstall dependencies
pip install -r requirements_versions.txt
# and restart the daemon
supervisorctl restart forge
```

---

## Troubleshooting

- If your token is invalid, the script will pause and repeatedly log a banner message to avoid rolling log loss in Vast’s UI.
- If a file gets stuck on download, remove the partially downloaded file and try again.
- Logs from `provisioning.sh` is located at `/var/log/portal/provisioning.log`. [[ref]](`forge_sync_config.yaml`)

---

## License

As required by the original repository, must keep using Vast.ai Elastic License.
