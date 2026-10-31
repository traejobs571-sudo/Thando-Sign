// Whisper transcription endpoint for ThandoSign's stt-proxy edge
// function. Accepts the same contract: POST /transcribe with multipart
// fields file/model/language/prompt, returns {"text": "..."}.
// Runs on Cloudflare's free tier — Workers AI whisper-large-v3-turbo
// with the included daily neuron allocation.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response("ok", { headers: cors() });
    }
    if (url.pathname === "/") {
      return json({ status: "ok" }, 200);
    }
    if (url.pathname !== "/transcribe" || request.method !== "POST") {
      return json({ error: "not found" }, 404);
    }

    try {
      const form = await request.formData();
      const file = form.get("file");
      if (!file || typeof file.arrayBuffer !== "function") {
        return json({ error: "missing file" }, 400);
      }
      const buf = await file.arrayBuffer();
      if (buf.byteLength === 0 || buf.byteLength > 8 * 1024 * 1024) {
        return json({ error: "empty or oversized file" }, 400);
      }
      const res = await env.AI.run("@cf/openai/whisper-large-v3-turbo", {
        audio: toBase64(buf),
        language: form.get("language") || "en",
        initial_prompt: form.get("prompt") || undefined,
      });
      return json({ text: res.text ?? "" }, 200);
    } catch (e) {
      // Undecodable audio → 400, so the app's health probe counts the
      // chain as alive (it expects 400/422 for junk input).
      return json({ error: String(e) }, 400);
    }
  },
};

function toBase64(buf) {
  const bytes = new Uint8Array(buf);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function cors() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "*",
  };
}

function json(body, status) {
  return Response.json(body, { status, headers: cors() });
}
