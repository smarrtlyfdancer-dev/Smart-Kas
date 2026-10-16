# Backend Setup (Supabase)

This is backend milestone 1: managed phone authentication, role-bound profiles, merchant applications, catalog/offer records, and a protected order/payment schema. It does not yet make checkout, payment, refunds, or fulfillment production-ready. Those writes have no browser policies and require trusted server functions in a later milestone.

## Hosted integration test (recommended first)

Use a dedicated Supabase staging/test project and Vercel Preview deployment. This exercises the hosted database, Auth, TLS, environment injection, and deployed browser behavior without treating the unfinished order/payment system as production commerce.

### 1. Create the hosted Supabase project

1. In the Supabase Dashboard, create an organization if needed, then create a project named `smart-kasua-staging`.
2. Choose a region close to the first users and delivery operations. Compare available regions and latency; do not pick a region solely by name.
3. Save the database password in a password manager. Do not paste it into chat or commit it.
4. After the project finishes provisioning, open **Project Settings > API** (or the API Keys page). Copy the Project URL and the publishable/anon client key. The client key is designed to be public; the service-role/secret key is not.

### 2. Configure phone authentication

1. Open **Authentication > Sign In / Providers** and enable Phone.
2. To test without sending SMS, open the Phone provider's **Test Phone Numbers and OTPs** settings and add a dedicated test number and fixed OTP. Use a test-only number in E.164 format, for example `+2348012345678`, and enter its configured OTP in the app. Supabase will accept the mapped test credentials without delivering a text message. Never use this bypass for real users; keep the test number private to the staging project.
3. A real SMS provider is not needed for the configured test number. Add one later, directly in the Supabase Dashboard, before testing sign-in to real phone numbers. Provider credentials stay out of the app and Vercel variables.
4. Set OTP expiry/request limits and keep rate limits enabled. Set the Auth Site URL to your Vercel Preview origin and add the exact preview/deployed origins to allowed redirect URLs.
5. If your project's dashboard does not show test phone numbers, continue with the database migration and Vercel preview setup, but OTP verification will be blocked until a supported SMS provider is configured.

### 3. Apply the database migration

Install the Supabase CLI using Supabase's current Windows instructions. Docker is not required to link and push migrations to a hosted project.

From the repository root, authenticate and link the staging project:

```sh
supabase login
supabase link --project-ref YOUR_STAGING_PROJECT_REF
supabase db push
```

The CLI may request the database password in the terminal. Enter it there; do not put it in source files. Inspect the migration plan/output and confirm the destination is the staging project before applying. Then run Supabase **Security Advisor** and check that every exposed table has the intended RLS policies.

### 4. Connect the Vercel Preview deployment

In Vercel, open the project **Settings > Environment Variables** and add these for **Preview** only:

```text
VITE_SUPABASE_URL=https://YOUR_STAGING_PROJECT_REF.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_STAGING_PUBLISHABLE_OR_ANON_KEY
```

Use the key field shown by Supabase. If it is a newer publishable key, it is still the client key consumed by the current `VITE_SUPABASE_ANON_KEY` setting. Add no service-role key to Vercel frontend variables. Save, then redeploy a Preview deployment; Vercel environment changes apply to new deployments, not existing ones.

Push the backend code to a non-production branch to create a Vercel Preview deployment. Test there before promoting changes to `main`.

### 5. Verify the hosted integration

- Register one test consumer using a controlled phone destination and verify the OTP.
- Sign out and sign back in with the same phone; confirm the profile role remains `consumer`.
- Try selecting the other role for that same account; confirm the app rejects the mismatch.
- Register a test merchant; confirm its application is `pending` and it cannot reach merchant tools.
- In Supabase, confirm profile and merchant application rows exist and use Security Advisor/API checks to verify cross-user reads/writes are denied.
- Confirm checkout, payment, refund, payout, and fulfillment remain unavailable. They must stay disabled until server-side order transactions and provider integrations are implemented.

### 6. Promote only after production gates

Do not point real customers at this project yet. The app currently has no server-side order creation, inventory reservation, payment initiation/webhook verification, settlement, refund workflow, merchant-review console, or production delivery workflow. Before launch, create a separate production Supabase project, apply the reviewed migrations there, configure production SMS and domains, set Vercel **Production** variables separately, and complete security, backup, privacy/legal, payment, and operational reviews.

## Optional local Supabase

Local Supabase is not required for the hosted integration path. If you later need isolated/offline database work, install Docker Desktop and the Supabase CLI, then run `supabase start` and `supabase db reset`. Local phone OTP uses the local development mail/SMS tooling and does not test real provider delivery.

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

`.env` and `.env.*` are ignored by Git; `.env.example` is the safe template. The Supabase publishable/anon client key may be exposed to the browser only because RLS is the access boundary. Never expose a service-role key, database password, SMS-provider secret, or payment-provider secret. If a secret is ever committed, rotate it in its provider even after removing it from Git history.
