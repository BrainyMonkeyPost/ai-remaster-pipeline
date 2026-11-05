# Running ARP on an Apple Silicon Mac

This is a community port. Windows + NVIDIA is still the main supported path, and the
Mac path has been built and unit-tested but not yet run end to end on every stage.

## What you need

| | |
|---|---|
| **Mac** | Apple Silicon (M1/M2/M3/M4). 64 GB unified memory or more recommended (the 22B LTX video models are large). |
| **macOS** | 14 Sonoma or later (needed for bfloat16 on the Apple GPU) |
| **Homebrew** | https://brew.sh |
| **Disk** | 150-250 GB free for models and intermediates. An external SSD is fine. |

You do **not** need to install Python yourself. The installer uses `uv` to download
CPython **3.13** into ARP's own `.venv`, so other Python versions on the Mac can't
clash with it.

## Install

```bash
git clone https://github.com/dtaddis/ai-remaster-pipeline.git
cd ai-remaster-pipeline
./install_macos.sh
```

The installer:

1. Checks the Mac (Apple Silicon, macOS 14+, memory, free disk).
2. Installs `git`, `uv` and `ffmpeg` with Homebrew. If Homebrew's standard `ffmpeg`
   lacks vid.stab or VP9, it tries the `ffmpeg-full` formula.
3. Creates `.venv` with Python 3.13 and checks it is native arm64.
4. Installs PyTorch from PyPI and checks the Apple GPU (MPS) works.
5. Clones ComfyUI into `tools/comfyui` and installs the same custom nodes as the Windows
   installer, except FlashVSR, which needs NVIDIA.
6. Writes `.ai_remaster_config.json`.

Re-run it any time to update. `./install_macos.sh --recreate-venv` rebuilds the Python
environment from scratch. `--comfy-dir PATH` uses a ComfyUI you already have.

Gated models such as Stable Audio Open need a Hugging Face login:

```bash
.venv/bin/hf auth login --force
```

## Launch

```bash
./launch_gui.sh
```

or double-click **Launch ARP.command** in Finder. ComfyUI starts in the same Terminal
window. Models download the first time a stage needs them.

## What changes on a Mac

* PyTorch runs on the Apple GPU through Metal (MPS). ComfyUI picks this up on its own.
  `PYTORCH_ENABLE_MPS_FALLBACK=1` is set so the few operations Metal lacks run on the CPU
  instead of failing.
* ARP's own GPU code (DeVignette, SAM2 masks, CMNET2) and the bundled Deep Exemplar and
  ColorMNet nodes now pick CUDA, then MPS, then CPU, instead of assuming CUDA.
* **Upscaling** defaults to SeedVR2 with fp16 weights. FlashVSR is not available
  (it needs Triton/CUDA).
* The status bar shows **GPU: MPS** instead of a CUDA compute capability.
* The Mac is kept awake with `caffeinate` while a stage runs.

## Stage by stage

| Stage | On a Mac | Notes |
|---|---|---|
| Clean Up | Expected to work | DeVignette runs on MPS. Dearchive uses the LTX 2.3 models in ComfyUI. |
| Stabilization | Works | FFmpeg vid.stab, CPU only. |
| Outpainting | Expected to work, slow | LTX 2.3 GGUF. Heaviest stage; consider RunPod for long films. MiniMax H3 is unlikely to work. |
| Shot Detection | Works | OpenCV, CPU. |
| Reference Generation | Expected to work | Qwen Image Edit 2511 GGUF or OpenAI. Qwen-Image-2.1 (int8 "convrot" weights) is unlikely to work. |
| Colorization | Expected to work | Deep Exemplar, ColorMNet and CMNET2 patched for MPS. LTX Colorizer runs in ComfyUI. OpenAI works. |
| Recomposition | Works | FFmpeg/NumPy. |
| Create Audio Track | Expected to work | Stable Audio Open and MMAudio via ComfyUI. |
| Upscaling | SeedVR2 / LTX 2.5 | FlashVSR is NVIDIA-only. |

### Known risks

* **fp8 model files.** Some default models are fp8 (`*_fp8_*.safetensors`, e.g. the Gemma
  and Qwen text encoders). Apple's Metal backend has no fp8 type, so these rely on
  ComfyUI converting them to fp16 as it loads them. Current ComfyUI does this, but if a
  stage fails with *"Trying to convert Float8_e4m3fn to the MPS backend"*, update
  ComfyUI (re-run the installer) or switch that stage to a bf16/fp16 or GGUF model.
* **Speed.** Expect the big video models to run several times slower than on a high-end
  NVIDIA card. Every stage can run on a RunPod worker instead (API key in Settings).
* `sam2` compiles without its optional CUDA extension; masks still work.

## Troubleshooting

* **"Python 3.x found, 3.13 required"**: you don't need to fix your system Python. Run
  `./install_macos.sh --recreate-venv`.
* **ComfyUI says it's using the CPU**: check `.venv/bin/python -c "import torch; print(torch.backends.mps.is_available())"`
  prints `True`. If not, make sure Terminal isn't running under Rosetta.
* **Stabilization fails with "No such filter: vidstabdetect"**: `brew install ffmpeg-full`,
  then re-run the installer so ARP links to it.
