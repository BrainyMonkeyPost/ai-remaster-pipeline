"""Add ARP's Gemma 4 compatibility to ComfyUI-GGUF's loader.py.

Python port of Ensure-ComfyUIGGUFGemma4Support in install_windows.ps1, used by
install_macos.sh. Safe to run more than once.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ANCHOR = "        state_dict[sd_key] = GGMLTensor(torch_tensor, tensor_type=tensor.tensor_type, tensor_shape=shape)"
MARKER = "audio_embeddings_connector.learnable_registers"
BLOCK = '''

        # LTX 2.5 Gemma 4 GGUFs contain three raw BF16 parameters which bypass
        # GGUF-aware linear operations and must therefore be ordinary tensors.
        if (
            arch_str == "gemma4"
            and sd_key in {
                "audio_embeddings_connector.learnable_registers",
                "keyframes_abs_pos_embedding",
                "video_embeddings_connector.learnable_registers",
            }
            and tensor.tensor_type == gguf.GGMLQuantizationType.BF16
        ):
            state_dict[sd_key] = dequantize_tensor(state_dict[sd_key], dtype=torch.bfloat16)'''


def patch(text: str) -> tuple[str, bool]:
    changed = False
    if not re.search(r"(?m)^TXT_ARCH_LIST\s*=.*[\"']gemma4[\"']", text):
        updated, count = re.subn(r"(?m)^(TXT_ARCH_LIST\s*=\s*\{[^\r\n]*)(\}\s*)$", r'\1, "gemma4"\2', text, count=1)
        if not count:
            raise SystemExit("Could not add Gemma 4 support to ComfyUI-GGUF: TXT_ARCH_LIST has an unsupported layout.")
        text, changed = updated, True
    if MARKER not in text:
        if ANCHOR not in text:
            raise SystemExit("Could not add Gemma 4 support to ComfyUI-GGUF: state-dict loader has an unsupported layout.")
        text, changed = text.replace(ANCHOR, ANCHOR + BLOCK, 1), True
    return text, changed


def main() -> None:
    path = Path(sys.argv[1])
    if not path.is_file():
        raise SystemExit(f"ComfyUI-GGUF loader was not found: {path}")
    text, changed = patch(path.read_text(encoding="utf-8"))
    if changed:
        path.write_text(text, encoding="utf-8")
        print("Installed ARP Gemma 4 compatibility for ComfyUI-GGUF.")
    else:
        print("ComfyUI-GGUF Gemma 4 compatibility already installed.")


if __name__ == "__main__":
    main()
