---
name: my-gen-image
description: Generate or edit images with the local Mac image models (e.g., FLUX) via the my-gen-image CLI. Use whenever the user asks to create, draw, render, or modify an image.
---

# my-gen-image

Generate or edit images with the local Mac image engine. Run the CLI with the
bash tool; it needs no setup beyond the VM's normal environment.

    my-gen-image [--model ID] [--size WxH] [--out PATH] [--] PROMPT [IMAGE ...]

- PROMPT is one quoted argument, after all options (and after `--` if any
  option could be confused with a prompt).
- IMAGE files (any number) make it an *edit*: the request goes to the
  engine's /images/edits endpoint with those images as references.
- `--model` defaults to the first image-outputting model in INFER_MODELS
  (currently `flux2-klein-4b`). See the listing with `jq -r '.url, .models[].id' <<<"$INFER_MODELS"`.
- `--size` is e.g. `512x512`; omit it for the model's own size.
- `--out` is the output path; the default is `my-gen-image-<timestamp>.png` in
  the current directory.
- On success it prints the saved PNG path(s) to stdout, one per line. On
  failure it prints an error to stderr and exits nonzero. Generation can
  take up to a few minutes; give the bash call a generous timeout.

Examples:

    my-gen-image --out photo.png "a photorealistic red apple on a wooden table"
    my-gen-image --out face.png "add googly eyes and a mustache to it" photo.png

After a successful call, show the result by reading the printed path with the
read tool (the model can see PNGs).

Notes:

- The INFER_MODELS listing currently claims flux2-klein-4b takes no image
  input; that is a suspected bug in the host's model metadata. my-gen-image
  works around it: pass image files and it uses /images/edits anyway.
