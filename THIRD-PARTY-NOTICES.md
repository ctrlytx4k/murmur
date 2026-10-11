# Third-party notices

Murmur itself is MIT licensed (see `LICENSE`). It is built on the following work by others.

## FluidAudio

Speech recognition runtime for Apple devices, by FluidInference.
https://github.com/FluidInference/FluidAudio

Licensed under the Apache License, Version 2.0. The full text is in `Licenses/FluidAudio-LICENSE.txt`.
Murmur uses FluidAudio unmodified, as a Swift package.

FluidAudio includes code from other projects under their own licenses. Those notices are reproduced in `Licenses/FluidAudio-ThirdParty/`.

## Parakeet TDT 0.6B v3 (speech model)

The speech model Murmur downloads on first use, created by NVIDIA and converted to Core ML by FluidInference.
https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml

Licensed under Creative Commons Attribution 4.0 International (CC BY 4.0).
https://creativecommons.org/licenses/by/4.0/

The model is not bundled with Murmur. It is downloaded to this Mac and used unmodified.

## Apple SpeechAnalyzer

The built-in engine uses Apple's Speech framework, which is part of macOS.
