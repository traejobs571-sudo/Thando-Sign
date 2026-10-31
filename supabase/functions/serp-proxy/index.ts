// SerpAPI proxy — keeps the API key server-side so it never ships in
// the APK. Deploy: `supabase functions deploy serp-proxy` then
// `supabase secrets set SERPAPI_KEY=<key>`.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { q, engine } = await req.json();
    const key = Deno.env.get("SERPAPI_KEY");
    if (!q || !key) {
      return new Response(
        JSON.stringify({ error: "missing query or SERPAPI_KEY" }),
        {
          status: 400,
          headers: { ...cors, "Content-Type": "application/json" },
        },
      );
    }
    const url =
      `https://serpapi.com/search.json?engine=${engine ?? "duck_ai"}` +
      `&q=${encodeURIComponent(q)}&api_key=${key}`;
    const res = await fetch(url);
    return new Response(await res.text(), {
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
