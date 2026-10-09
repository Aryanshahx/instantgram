# Photo check model

`nsfw_mobilenet_v2_q.tflite` is the MobileNet V2 (1.4, 224 px) model from
[GantMan/nsfw_model](https://github.com/GantMan/nsfw_model) release 1.2.0 (MIT licence),
converted to TensorFlow Lite with weight quantization (4.7 MB instead of 17 MB).

- Input: 1 x 224 x 224 x 3 float32, RGB values divided by 255 (image squashed to 224 x 224).
- Output: 5 probabilities in this order: drawings, hentai, neutral, porn, sexy.

The app downloads this file the first time someone uploads (from this repository's `main`
branch, see `kNsfwModelUrl` in `lib/services/image_check.dart`) and checks photos on the phone.
Nothing is sent anywhere.

MIT License, Copyright (c) 2019 Gant Laborde.
