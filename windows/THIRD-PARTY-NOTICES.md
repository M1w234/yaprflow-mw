# Third-party notices

yaprflow is an Apache-2.0 fork of Tim Moreton's yaprflow, with contributions by Team Wong. See LICENSE.txt.

Windows dependencies (retain their package license notices in distributions):
- sherpa-onnx, k2-fsa / Xiaomi: Apache-2.0, https://github.com/k2-fsa/sherpa-onnx
- ONNX Runtime, Microsoft: MIT, https://github.com/microsoft/onnxruntime
- NAudio, Mark Heath and contributors: MIT, https://github.com/naudio/NAudio
- SharpCompress and contributors: MIT, https://github.com/adamhathcock/sharpcompress
- .NET / WPF / Windows Forms, Microsoft and contributors: MIT, https://github.com/dotnet

The optional model download is NVIDIA Parakeet TDT 0.6B v2, converted to ONNX by the sherpa-onnx project. Model: CC-BY-4.0, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 . Conversion changes the serialization and quantizes the weights to int8. Attribution is retained here and in the model source manifest. No endorsement by NVIDIA or upstream authors is implied.

The model is a separate first-run download, not included in the small application installer. Once downloaded, recognition is offline. Source and hash: src/YaprFlow.Speech/ModelCatalog.cs.

AI Polish dependencies:
- LLamaSharp 0.27.0, SciSharp contributors: MIT, https://github.com/SciSharp/LLamaSharp
- llama.cpp / ggml CPU backend and contributors: MIT, https://github.com/ggml-org/llama.cpp
- Qwen3-0.6B Q8_0 GGUF, Qwen / Alibaba Cloud: Apache-2.0, https://huggingface.co/Qwen/Qwen3-0.6B-GGUF . Optional separate 639,446,688-byte download pinned to revision 23749fefcc72300e3a2ad315e1317431b06b590a. Source and SHA-256 are in src/YaprFlow.Polish/PolishModel.cs. No cloud inference or third-party server is used.

Built-in start/stop WAV cues are original generated assets. Imported custom sounds remain the user's local files.
