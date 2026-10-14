# Backend Setup (Supabase)

This is backend milestone 1: managed phone authentication, role-bound profiles, merchant applications, catalog/offer records, and a protected order/payment schema. It does not yet make checkout, payment, refunds, or fulfillment production-ready. Those writes have no browser policies and require trusted server functions in a later milestone.

## Local setup

1. Install the Supabase CLI and Docker Desktop. Docker is required only for the local Supabase stack.
2. Start the local services and apply migrations:

   ```sh
   supabase start
   supabase db reset
   supabase status
   ```

3. Copy `.env.example` to `.env.local`. Use the local API URL and the **anon/public key** reported by `supabase status`:

   ```env
   VITE_SUPABASE_URL=http://127.0.0.1:54321
   VITE_SUPABASE_ANON_KEY=your-local-anon-key
   ```

4. Start Vite with `npm run dev`. Local phone OTP delivery uses the local Supabase/Inbucket development setup; do not use local test credentials in production.

## Hosted Supabase project

1. Create a Supabase project in the selected region and configure phone authentication with an SMS provider, OTP limits, and production redirect URLs.
2. Link the project and apply the committed migrations:

   ```sh
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   ```

3. In Vercel, add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` for the intended environments, then redeploy.
4. Set the Supabase Auth Site URL and allowed redirect URLs to the deployed application origin.

Never add a Supabase `service_role` key, database password, SMS-provider secret, or payment-provider secret to a `VITE_` variable. The anon key is intentionally public; Row Level Security is the access boundary.

## Current schema/security boundary

- A database trigger creates one profile per Supabase Auth user and fixes its account type as `consumer` or `merchant`.
- Phone uniqueness is delegated to Supabase Auth; application rules never create a second role for the same authenticated identity.
- Merchant applications can only be submitted as `pending`. There is no client policy to approve, reject, or change verification status.
- Only verified merchants can expose offers or write offer changes. Product creation/moderation remains a trusted administrative operation.
- Customers and participating merchants can read only the order records allowed by the migration's RLS policies. Clients cannot insert or mutate orders, payments, payment-webhook events, refunds, shipments, or order events.
- `price_minor_units` is integer minor currency units (kobo for NGN); convert only at display boundaries and never use floating-point values for financial calculations.
- The existing demo cart and checkout are not connected to this schema. Do not accept real orders/payments until server-side checkout, inventory reservation, idempotency, verified provider webhooks, settlement rules, and reconciliation are implemented and tested.

## Local environment safety

`.env` and `.env.*` are ignored by Git; `.env.example` is the safe template. If a secret is ever committed, rotate it in its provider even after removing it from Git history.
