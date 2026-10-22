# Fleet side projects: what else the hardware can do

A planning list, written 2026-10-22 at the owner's request: what the fleet can run besides the coding agent, from local
models to video, VFX, 3D and home-lab services. Nothing here is installed or scheduled. Items with a link were checked
against the project's own page on 2026-10-22; the rest are from general knowledge as of mid-2026 and **must be
re-verified before an install** (this field moves monthly). Sources are in [references.md](references.md) →
"Side-project tools".

## What each machine is good for

| Machine | GPU | Suits | Constraint |
|---|---|---|---|
| server | RTX 4070 Ti Super 16 GB, CUDA | the heavy generation (video, FLUX, LoRA training), always-on services | it is the model host: qwen3.6 holds its GPU, and its 3700X is the weakest CPU (keep CPU work off it) |
| node3 | RTX 3080 FE 10 GB, CUDA; Ryzen 9 5950X | CUDA work that fits 10 GB (SDXL, upscaling, splat training), and CPU-heavy work (encoding, photogrammetry) | a game PC (danaj's): run only when free |
| desktop | RX 6800 XT 16 GB (Vulkan); Ryzen 7 5800X3D, 32 GB RAM | LLMs on Vulkan, Blender, games | the owner's game PC; most PyTorch image and video tools are CUDA-first, and its RAM is suspect (`MEMORY_CORRUPTION_ONE_BIT` in the latest dump) |

**The main constraint is CUDA, not VRAM.** Most image, video and VFX tools target NVIDIA first, which makes the
server and node3 the creative machines. [ComfyUI](https://github.com/comfyanonymous/ComfyUI) now lists AMD on
Windows through AMD's multi-architecture PyTorch packages; whether those cover the 6800 XT (gfx1030) is unchecked,
and gfx1030 is unsupported by the Windows HIP SDK (`docs/troubleshooting.md`), so expect friction there.

**One big job per GPU.** Video generation and qwen3.6 cannot share the server's 16 GB. A "creative mode" that unloads
the llama.cpp seats (`POST /models/unload`) and reloads them after would make the switch clean, and it must not
overlap a benchmark round.

## Generation

- **Video:**
  - **Hub:** ComfyUI is the hub. It lists Wan 2.1/2.2, LTX-Video 2, HunyuanVideo 1.5, CogVideoX and Mochi among its
    video models.
  - **Wan 2.2's own README sets a high floor:** at least 80 GB for the 14B models on one GPU. The dense TI2V-5B needs
    24 GB with its offload flags ([Wan2.2](https://github.com/Wan-Video/Wan2.2)). On 16 GB that means community
    quantized builds (GGUF/fp8) and offloading, slow and unverified here.
  - **LTX-Video** is the lighter, faster option to try first.
  - **Image-to-video** animates stills or renders.
- **Images:** FLUX.1 (quantized) or SDXL / SD 3.5 in ComfyUI. SDXL fits node3, and FLUX is better on the server.
  Training LoRAs (a style, a character, the TTRPG world's look) with kohya or ai-toolkit fits 16 GB for FLUX.
- **Audio:**
  - **Transcription:** [faster-whisper](https://github.com/SYSTRAN/faster-whisper), on CPU (int8) or NVIDIA. Its
    page lists no AMD support.
  - **Text to speech:** Kokoro, F5-TTS or XTTS (voice cloning).
  - **Music:** ACE-Step or Stable Audio Open.

## VFX and post (CUDA: server or node3)

- **Rotoscoping:** [SAM 2](https://github.com/facebookresearch/sam2) segments an object from a click or box on one
  frame and tracks it through the clip. BiRefNet removes backgrounds.
- **Depth maps:** Depth Anything v2, for fake depth of field, relighting or parallax.
- **Upscaling and frame interpolation:** Real-ESRGAN, and RIFE for slow motion or smoothing.
- **Markerless motion capture** from ordinary video, to animate rigs in Blender.

## 3D

- **Gaussian splatting:** film a room or object on a phone and get a navigable scene.
  [gsplat](https://github.com/nerfstudio-project/gsplat) is built on CUDA kernels, so in practice this needs an NVIDIA
  card: server or node3.
- **Photogrammetry:** COLMAP or Meshroom, which suit node3's CPU.
- **Image to 3D mesh:** TRELLIS or Hunyuan3D 2.
- **A Blender render farm across all three machines** with [Flamenco](https://flamenco.blender.org/), Blender
  Studio's open-source render manager. It is the same "the fleet as one computer" idea as the coding agent. Cycles
  uses OptiX on the NVIDIA cards and HIP on the 6800 XT (the HIP claim is unverified).

## Home-lab services (light, always on: the server)

- **Photos:** [Immich](https://docs.immich.app/features/ml-hardware-acceleration), a photo library with smart search
  and face recognition. Its ML service accelerates on CUDA, ROCm or OpenVINO.
- **Cameras:** Frigate recording with GPU object detection.
- **Media:** Jellyfin with NVENC hardware transcoding.
- **Voice:** a local assistant from Home Assistant, Whisper, Piper and one of the fleet's LLMs.
- **Document search:** RAG over local documents with the embedding models already in `models/catalog.tsv`
  (`nomic-embed-text`, `mxbai-embed-large`).

## LLM side projects

- **Fine-tuning:** QLoRA of a small model on the server (Unsloth; `docs/roadmap.md` → "Third node: fine-tuning with
  Unsloth"), for example on the owner's repos or writing style.
- **A second-opinion code reviewer** from a different model family than the executor. The review-gate research
  (`docs/review-gate/`) says a local model can't be the gate, but it can still be a reader.

## If one is picked

ComfyUI on the server is the cheapest first step: it covers images, video and most of the VFX tools in one install.
Before installing:
1. re-check the current models and their VRAM;
2. write the GPU hand-off between it and llama.cpp;
3. keep it off the benchmark's server time.
