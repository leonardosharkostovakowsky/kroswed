// Vercel build step: writes config.js from environment variables when they are set.
const fs = require("fs");
const url = (process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || "").trim();
const key = (process.env.SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || "").trim();
if (url && key) {
  fs.writeFileSync("config.js", "window.KW_CONFIG = " + JSON.stringify({ url, key }) + ";\n");
  console.log("config.js generated from environment variables for", url);
} else {
  console.log("No SUPABASE_URL / SUPABASE_ANON_KEY env vars found; using config.js as committed.");
}
