// infer-images.js: a pi extension that lets pi make images with the Mac's
// image models (e.g., flux2-klein-4b), through its codemode tool:
//   const flux = await models.getModelOfType("image", "mac-local-images", "flux2-klein-4b");
//   const result = await models.generateImages(flux, { input: [{ type: "text", text: "a red apple" }] });
//   for (const block of result.output) if (block.type === "image") image(block);
// image() shows each image to the chat model (which can read images, if
// it has a vision projector) and saves it to a file. To edit images, add
// them to input as image blocks (e.g., from tools.read() or an earlier
// result); FLUX.2-klein uses them as references.
//
// nopi loads this (--extension), with infer-models' answer in
// INFER_MODELS, so this registers each model there that outputs images;
// it doesn't ask the engine itself. A separate provider, since
// registering models replaces a provider's whole list, and mac-local's
// chat models come from models.json. A request goes to llama-swap's
// /v1/images/generations, or with input images, to /v1/images/edits (as
// a form, with each image as image[]), with the API key pi resolves from
// INFER_API_KEY. vm-setup.sh installs this in /usr/local/libexec/bulkhead.
const API = "llama-swap-images";

export default function (pi) {
  let listing;
  try {
    listing = JSON.parse(process.env.INFER_MODELS ?? "");
  } catch {
    return; // nopi couldn't reach the engine, so there's nothing to add.
  }
  const models = listing.models.filter((m) => m.output.includes("image"));
  if (models.length === 0) return;
  pi.registerProvider("mac-local-images", {
    apiKey: "$INFER_API_KEY",
    models: models.map((m) => ({
      type: "image",
      id: m.id,
      name: m.name,
      api: API,
      baseUrl: listing.url,
      input: ["text", "image"],
      output: ["image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    })),
    images: { [API]: { generateImages } },
  });
}

export async function generateImages(model, context, options) {
  const result = {
    api: model.api,
    provider: model.provider,
    model: model.id,
    output: [],
    stopReason: "stop",
    timestamp: Date.now(),
  };
  try {
    const prompt = context.input
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n");
    const images = context.input.filter((block) => block.type === "image");
    let path = "generations";
    let body = JSON.stringify({ model: model.id, prompt });
    const headers = { Authorization: `Bearer ${options?.apiKey}` };
    if (images.length > 0) {
      path = "edits";
      body = new FormData();
      body.append("model", model.id);
      body.append("prompt", prompt);
      images.forEach((image, i) => {
        const type = image.mimeType;
        body.append("image[]", new Blob([Buffer.from(image.data, "base64")], { type }), `${i}.${type.split("/")[1]}`);
      });
    } else {
      headers["Content-Type"] = "application/json";
    }
    const response = await fetch(`${model.baseUrl}/images/${path}`, {
      method: "POST",
      headers,
      body,
      signal: options?.signal,
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    }
    for (const image of (await response.json()).data ?? []) {
      if (image.b64_json) {
        result.output.push({ type: "image", data: image.b64_json, mimeType: "image/png" });
      }
    }
    // sd-server answers 200 with no image if it couldn't make one.
    if (result.output.length === 0) throw new Error("the engine returned no image");
  } catch (error) {
    result.stopReason = options?.signal?.aborted ? "aborted" : "error";
    result.errorMessage = String(error);
  }
  return result;
}
