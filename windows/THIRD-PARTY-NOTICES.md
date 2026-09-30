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
