# Kroswed — English Crossword & Knowledge Game
Created and Developed by Muhammad Ilham Ramadhan (@iaamramadhan)
© 2026 Muhammad Ilham Ramadhan. All rights reserved.

Static frontend (no build step) + Supabase (Auth, Postgres, RLS) for accounts, scoring and leaderboards.

## 1. Supabase
1. Create a project at supabase.com.
2. SQL Editor > paste all of `schema.sql` > Run.
3. Authentication > URL Configuration: set Site URL to your Vercel domain (needed for email confirmation and password reset links).
4. Project Settings > API: copy the Project URL and the anon public key.

## 2. Configure (pick one)
- A: edit `config.js` with the Project URL and anon key, then redeploy.
- B: in Vercel > Settings > Environment Variables add `SUPABASE_URL` and `SUPABASE_ANON_KEY` (all environments), then Redeploy. `build.js` writes config.js from them.
Never use the service_role key.

## 3. Deploy to Vercel
- CLI: `npm i -g vercel`, then `vercel --prod` in this folder (Framework: Other, no build command).
- Or push to GitHub, import in Vercel, Framework Preset "Other", Deploy.

## Security model
- Points, XP, and ranks are written only by the `submit_completion` database function. Clients cannot update points or XP directly (column privileges + RLS).
- The function checks submitted answers against the stored answer key, minimum solve time, a daily cap, and awards each answer-set once per user.
- Limits: puzzles are generated in the browser, so hint counts and timing are self-reported. A determined cheater can still submit valid answers without playing; the daily cap and one-reward-per-answer-set limit bound the damage. Fully trusted scoring needs server-issued puzzles.
- Leaderboards use Asia/Jakarta (WIB); weeks start Monday.
- Anti-repetition history (recent layouts and clues) is stored per browser, not synced.
