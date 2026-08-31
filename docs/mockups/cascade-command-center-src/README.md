# Cascade Command Center mockup source

This React/Vite project is the editable source for the complete Command Center, Cleaner Checklist, and Direct Booking design suite in the parent directory. It uses sample data only and has no Supabase, n8n, Telegram, bank, or guest-channel integration.

## Run locally

```powershell
npm install
npm run dev
```

## Validate

```powershell
npm run build
npm run lint
```

The portable review artifacts are `../cascade-experience-mockups.html` and the compatibility alias `../cascade-command-center-mockup.html`. Production implementation should use server-side authorization, the canonical Supabase data model, and idempotent n8n actions. The role switch in this mockup demonstrates the intended information boundary but is not an authorization mechanism.
