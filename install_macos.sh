#!/usr/bin/env bash
# ARP installer for Apple Silicon Macs (M1/M2/M3/M4, macOS 14 or later).
#
# Mirrors install_windows.ps1, with these differences:
#   * Python is pinned to CPython 3.13 and fetched by uv, so whatever other
#     Python versions are on the Mac (Homebrew, python.org, Xcode) don't matter.
#   * PyTorch comes from PyPI; its macOS arm64 wheels use the Apple GPU via Metal (MPS).
#   * No xFormers, Triton, FlashVSR or CUDA build steps (NVIDIA-only).
#   * FFmpeg comes from Homebrew.
#
# Usage:
#   ./install_macos.sh                     # install or update
#   ./install_macos.sh --comfy-dir PATH    # use an existing ComfyUI checkout
#   ./install_macos.sh --skip-comfy-manager
#   ./install_macos.sh --recreate-venv     # delete .venv and rebuild it
#
# Re-running is safe: it updates ComfyUI and the custom nodes and keeps models and outputs.

set -euo pipefail

PYTHON_VERSION="3.13"
ROOT="$(cd "$(dirname "$0")" && pwd)"
COMFY_DIR=""
SKIP_COMFY_MANAGER=0
RECREATE_VENV=0

while [ $# -gt 0 ]; do
  case "$1" in
    --comfy-dir) COMFY_DIR="$2"; shift 2 ;;
    --comfy-dir=*) COMFY_DIR="${1#*=}"; shift ;;
    --skip-comfy-manager) SKIP_COMFY_MANAGER=1; shift ;;
    --recreate-venv) RECREATE_VENV=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

COMFY_MANAGED=true
if [ -z "$COMFY_DIR" ]; then
  COMFY_DIR="$ROOT/tools/comfyui"
else
  COMFY_MANAGED=false
  COMFY_DIR="$(cd "$COMFY_DIR" && pwd)"
fi
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
BUNDLED_NODES="$ROOT/vendor/comfyui_custom_nodes"
VENV="$ROOT/.venv"
PY="$VENV/bin/python"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
step "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || die "This installer is for macOS. On Windows use install_windows.bat."
[ "$(uname -m)" = "arm64" ] || die "An Apple Silicon Mac (arm64) is required. Intel Macs have no usable GPU backend for these models."
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
  die "This Terminal is running under Rosetta (x86_64). Open a native Terminal and run the installer again."
fi
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] || die "macOS 14 (Sonoma) or later is required for bfloat16 on the Apple GPU. This Mac has $(sw_vers -productVersion)."
RAM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
echo "macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), ${RAM_GB} GB unified memory"
if [ "$RAM_GB" -lt 64 ]; then
  warn "Under 64 GB of memory. The 22B LTX video models may not fit; consider running Outpainting on RunPod."
fi
FREE_GB=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
if [ "${FREE_GB:-0}" -lt 150 ]; then
  warn "Only ${FREE_GB} GB free on this disk. Models and intermediates need 150-250 GB."
fi

# --------------------------------------------------------------------------
step "Checking Homebrew tools (git, ffmpeg, uv)"
if ! command -v brew >/dev/null 2>&1; then
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$candidate" ] && eval "$("$candidate" shellenv)" && break
  done
fi
command -v brew >/dev/null 2>&1 || die "Homebrew is required. Install it from https://brew.sh, then run this installer again."
for formula in git uv ffmpeg; do
  if brew list --formula "$formula" >/dev/null 2>&1; then
    echo "Homebrew $formula: installed"
  else
    brew install "$formula"
  fi
done

# ARP's Stabilization stage needs vid.stab, and intermediates use VP9 (libvpx).
ffmpeg_ok() {
  # Capture first: piping into `grep -q` makes ffmpeg exit with SIGPIPE, which
  # `set -o pipefail` turns into a failure even on a good build.
  local bin="$1" filters encoders
  filters="$("$bin" -hide_banner -filters 2>/dev/null || true)"
  encoders="$("$bin" -hide_banner -encoders 2>/dev/null || true)"
  [[ "$filters" == *vidstabdetect* && "$encoders" == *libvpx-vp9* ]]
}
FFMPEG_BIN="$(command -v ffmpeg || true)"
if [ -z "$FFMPEG_BIN" ] || ! ffmpeg_ok "$FFMPEG_BIN"; then
  echo "Homebrew's standard ffmpeg lacks vid.stab or libvpx; trying the ffmpeg-full formula."
  if brew info --formula ffmpeg-full >/dev/null 2>&1; then
    brew list --formula ffmpeg-full >/dev/null 2>&1 || brew install ffmpeg-full
    FULL_PREFIX="$(brew --prefix ffmpeg-full)"
    if [ -x "$FULL_PREFIX/bin/ffmpeg" ] && ffmpeg_ok "$FULL_PREFIX/bin/ffmpeg"; then
      FFMPEG_BIN="$FULL_PREFIX/bin/ffmpeg"
    fi
  fi
fi
if [ -n "$FFMPEG_BIN" ] && ffmpeg_ok "$FFMPEG_BIN"; then
  echo "FFmpeg with vid.stab and VP9: $FFMPEG_BIN"
else
  warn "No FFmpeg with both vid.stab and libvpx-vp9 was found. Stabilization may fail; other stages should work."
  FFMPEG_BIN="$(command -v ffmpeg)"
fi
# ARP looks in .cache/tools/ffmpeg first, so point it at the chosen build.
mkdir -p "$ROOT/.cache/tools/ffmpeg"
ln -sf "$FFMPEG_BIN" "$ROOT/.cache/tools/ffmpeg/ffmpeg"
ln -sf "$(dirname "$FFMPEG_BIN")/ffprobe" "$ROOT/.cache/tools/ffmpeg/ffprobe"

# --------------------------------------------------------------------------
step "Creating Python $PYTHON_VERSION environment (.venv)"
if [ "$RECREATE_VENV" = 1 ] && [ -d "$VENV" ]; then
  echo "Removing existing .venv"
  rm -rf "$VENV"
fi
if [ -x "$PY" ]; then
  HAVE="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo broken)"
  if [ "$HAVE" != "$PYTHON_VERSION" ]; then
    warn ".venv uses Python $HAVE, not $PYTHON_VERSION. Rebuilding it."
    rm -rf "$VENV"
  fi
fi
if [ ! -x "$PY" ]; then
  uv python install "$PYTHON_VERSION"
  # --seed adds pip, which ARP uses for on-demand installs.
  uv venv --seed --python "$PYTHON_VERSION" "$VENV"
fi
"$PY" - <<'PYCHECK'
import platform, sys, sysconfig
assert sys.version_info[:2] == (3, 13), f"Expected Python 3.13, got {platform.python_version()}"
assert platform.machine() == "arm64", f"Expected arm64 Python, got {platform.machine()}"
assert not sysconfig.get_config_var("Py_GIL_DISABLED"), "Free-threaded Python is not supported by PyTorch wheels"
print(f"Python {platform.python_version()} ({platform.machine()}) at {sys.executable}")
PYCHECK

pip_install() { "$PY" -m pip install --disable-pip-version-check "$@"; }

# Install a requirements file but skip packages that only exist for NVIDIA GPUs.
pip_install_requirements() {
  local req="$1" label="$2" filtered
  [ -f "$req" ] || return 0
  filtered="$(mktemp -t arp-req)"
  grep -viE '^[[:space:]]*(triton|triton-windows|xformers|sageattention|flash[-_]attn|bitsandbytes|cupy|nvidia-|onnxruntime-gpu|deepspeed)([^a-z0-9_-]|$)' "$req" > "$filtered" || true
  if ! pip_install -r "$filtered"; then
    warn "Some requirements for $label could not be installed. That stage may not work on macOS."
  fi
  rm -f "$filtered"
}

pip_install --upgrade pip wheel setuptools

# --------------------------------------------------------------------------
step "Installing PyTorch (Apple GPU / MPS build from PyPI)"
pip_install --upgrade torch torchvision torchaudio
"$PY" - <<'PYCHECK'
import torch
assert torch.backends.mps.is_built(), "This PyTorch build has no MPS support"
assert torch.backends.mps.is_available(), "PyTorch cannot reach the Apple GPU (MPS). Check macOS is 14 or later."
x = torch.ones(4, device="mps", dtype=torch.bfloat16)
assert float((x * 2).sum()) == 8.0
print(f"PyTorch {torch.__version__}: Apple GPU (MPS) OK, bfloat16 OK")
PYCHECK

step "Installing ARP Python requirements"
# SAM2 tries to compile a CUDA extension; tell it not to.
export SAM2_BUILD_CUDA=0
pip_install -r "$ROOT/requirements.txt"
# httpx: dependency_manager.py imports it, and newer huggingface_hub no longer pulls it in.
pip_install "huggingface_hub[cli]" httpx opencv-contrib-python imageio-ffmpeg pillow numpy numba scikit-image einops tqdm matplotlib

# --------------------------------------------------------------------------
step "Installing ComfyUI"
clone_or_update() {
  local repo="$1" dest="$2"
  if [ -d "$dest/.git" ]; then
    echo "Updating $dest"
    git -C "$dest" pull --ff-only || warn "Could not update $dest (local changes?). Delete it and rerun to get a fresh copy."
  elif [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    warn "$dest exists but is not a Git checkout; leaving it as it is."
  else
    git clone --depth 1 "$repo" "$dest"
  fi
}
copy_bundled() {
  local name="$1" dest="$2"
  [ -d "$BUNDLED_NODES/$name" ] || return 1
  echo "Installing bundled custom node: $name"
  mkdir -p "$dest"
  cp -R "$BUNDLED_NODES/$name/." "$dest/"
}
if [ "$COMFY_MANAGED" = true ]; then
  clone_or_update https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  echo "Using existing ComfyUI at $COMFY_DIR (not updated by ARP)."
fi
[ -f "$COMFY_DIR/main.py" ] || die "ComfyUI main.py was not found in $COMFY_DIR"
pip_install_requirements "$COMFY_DIR/requirements.txt" "ComfyUI"

# --------------------------------------------------------------------------
step "Installing ComfyUI custom nodes"
mkdir -p "$CUSTOM_NODES"
if [ "$SKIP_COMFY_MANAGER" = 0 ]; then
  clone_or_update https://github.com/ltdrdata/ComfyUI-Manager.git "$CUSTOM_NODES/ComfyUI-Manager"
fi
copy_bundled ComfyUI-LTXVideo "$CUSTOM_NODES/ComfyUI-LTXVideo" ||
  clone_or_update https://github.com/Lightricks/ComfyUI-LTXVideo.git "$CUSTOM_NODES/ComfyUI-LTXVideo"
rm -f "$CUSTOM_NODES/ComfyUI-LTXVideo/guide_attention_patch.py"
copy_bundled ComfyUI-ARP "$CUSTOM_NODES/ComfyUI-ARP" || die "Bundled ComfyUI-ARP custom node is missing."
clone_or_update https://github.com/city96/ComfyUI-GGUF.git "$CUSTOM_NODES/ComfyUI-GGUF"
clone_or_update https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git "$CUSTOM_NODES/ComfyUI-VideoHelperSuite"
clone_or_update https://github.com/daniabib/ComfyUI_ProPainter_Nodes.git "$CUSTOM_NODES/ComfyUI_ProPainter_Nodes"
clone_or_update https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git "$CUSTOM_NODES/ComfyUI-SeedVR2_VideoUpscaler"
clone_or_update https://github.com/kijai/ComfyUI-MMAudio.git "$CUSTOM_NODES/ComfyUI-MMAudio"
clone_or_update https://github.com/Jalen-Brunson/ComfyUI-MiniMax-H3-PDD-Acc.git "$CUSTOM_NODES/ComfyUI-MiniMax-H3-PDD-Acc"
copy_bundled reference-video-colorization "$CUSTOM_NODES/reference-video-colorization" ||
  clone_or_update https://github.com/jonstreeter/ComfyUI-Reference-Based-Video-Colorization.git "$CUSTOM_NODES/reference-video-colorization"
# FlashVSR is skipped on purpose: it needs Triton and CUDA kernels, which don't exist on macOS.
if [ -d "$CUSTOM_NODES/ComfyUI-FlashVSR_Ultra_Fast" ]; then
  warn "ComfyUI-FlashVSR_Ultra_Fast is installed but cannot run on macOS; ComfyUI will log an import error for it."
fi

"$PY" "$ROOT/scripts/macos_patch_gguf.py" "$CUSTOM_NODES/ComfyUI-GGUF/loader.py"

# ComfyUI-MMAudio hard-codes .cuda() on four VAE buffers; drop it so they follow the module to MPS.
MMAUDIO_VAE="$CUSTOM_NODES/ComfyUI-MMAudio/mmaudio/ext/autoencoder/vae.py"
if [ -f "$MMAUDIO_VAE" ] && grep -q 'dtype=torch.float32).cuda())' "$MMAUDIO_VAE"; then
  sed -i '' 's/dtype=torch\.float32)\.cuda())/dtype=torch.float32))/' "$MMAUDIO_VAE"
  echo "Patched ComfyUI-MMAudio VAE buffers for Apple GPU."
fi

step "Installing custom node requirements"
for node in ComfyUI-LTXVideo ComfyUI-GGUF ComfyUI-VideoHelperSuite ComfyUI_ProPainter_Nodes \
            ComfyUI-SeedVR2_VideoUpscaler ComfyUI-MMAudio ComfyUI-MiniMax-H3-PDD-Acc reference-video-colorization; do
  pip_install_requirements "$CUSTOM_NODES/$node/requirements.txt" "$node"
done

# --------------------------------------------------------------------------
step "Creating model folders"
for dir in checkpoints diffusion_models loras text_encoders unet vae latent_upscale_models mmaudio SEEDVR2; do
  mkdir -p "$COMFY_DIR/models/$dir"
done

step "Writing local ARP configuration"
"$PY" - "$ROOT/.ai_remaster_config.json" "$COMFY_DIR" "$COMFY_MANAGED" <<'PYCONFIG'
import json, sys
from pathlib import Path
path, comfy_dir, managed = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
config = {}
if path.exists():
    try:
        config = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        config = {}
config.update({
    "comfy_dir": comfy_dir,
    "comfy_url": config.get("comfy_url", "http://127.0.0.1:8188"),
    "comfy_host": config.get("comfy_host", "127.0.0.1"),
    "comfy_port": config.get("comfy_port", "8188"),
    "comfy_managed_by_arp": managed,
})
path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
print(f"Wrote: {path}")
PYCONFIG

printf '\n\033[1;32mInstall complete.\033[0m\n'
echo "ComfyUI:            $COMFY_DIR"
echo "Python environment: $PY"
echo
echo "Start ARP with:  ./launch_gui.sh   (or double-click 'Launch ARP.command' in Finder)"
echo "Models download the first time each stage needs them."
echo "Gated models (Stable Audio Open etc.): accept access on Hugging Face, then run:"
echo "  $VENV/bin/hf auth login --force"
