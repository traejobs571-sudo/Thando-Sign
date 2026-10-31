// Speech-to-text proxy — forwards recorded clips to a self-hosted
// faster-whisper server so no transcription API key ships in the app.
// Deploy:
//   supabase functions deploy stt-proxy
//   supabase secrets set STT_SELFHOSTED_URL=http://your-host:8000
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// Bias hint steers the model toward the app's real vocabulary —
// Zimbabwean English names and phrases the OS recogniser kept
// mangling. Ignored by whisper servers that don't accept a prompt.
const PROMPT_HINT =
  "Zimbabwean English speech by a speaker at a Zimbabwean school. " +
  "Common names: Thando, Tariro, Tatenda, Ruvimbo, Nyasha, Kudzai, " +
  "Tendai, Chipo. Places: Harare, Bulawayo, Polytechnic College.";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { audio, format } = await req.json();
    if (!audio || typeof audio !== "string") {
      return new Response(JSON.stringify({ error: "missing audio" }), {
        status: 400,
        headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    const bytes = Uint8Array.from(atob(audio), (c) => c.charCodeAt(0));
    if (bytes.length === 0 || bytes.length > 8 * 1024 * 1024) {
      return new Response(
        JSON.stringify({ error: "audio too large or empty" }),
        { status: 400, headers: { ...cors, "Content-Type": "application/json" } },
      );
    }

    const selfHosted = Deno.env.get("STT_SELFHOSTED_URL");
    if (!selfHosted) {
      return new Response(
        JSON.stringify({ error: "STT_SELFHOSTED_URL not configured" }),
        { status: 503, headers: { ...cors, "Content-Type": "application/json" } },
      );
    }
    const form = new FormData();
    form.append(
      "file",
      new Blob([bytes], { type: `audio/${format ?? "m4a"}` }),
      `speech.${format ?? "m4a"}`,
    );
    form.append("model", "medium");
    form.append("language", "en");
    form.append("prompt", PROMPT_HINT);
    const res = await fetch(`${selfHosted.replace(/\/$/, "")}/transcribe`, {
      method: "POST",
      body: form,
    });
    const body = await res.text();
    return new Response(body, {
      status: res.status,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
