# Backend Setup (Supabase)

This is backend milestone 1: managed email/password authentication, role-bound profiles, merchant applications, catalog/offer records, and a protected order/payment schema. It does not yet make checkout, payment, refunds, or fulfillment production-ready. Those writes have no browser policies and require trusted server functions in a later milestone.

## Single hosted project workflow

Use the existing hosted Supabase project and Vercel Production deployment as requested. Do not configure SMS OTP. While this project is being privately tested, email confirmation may be temporarily disabled to let test accounts sign in immediately. Do not open registration to the public in that state.

### 1. Configure email/password authentication

1. Open **Authentication > Sign In / Providers > Email** and ensure Email is enabled.
2. Disable the **Phone** provider while OTP is not part of the login flow.
3. For private pre-release testing, turn off **Confirm email** so registrations receive a session immediately. Anyone who can reach the Production URL can register while confirmation is off, so use test data only and keep the site restricted if possible.
4. Set the Auth Site URL to your Vercel Production origin. Email/password auth requires no SMS provider or OTP delivery.
5. Before public launch, turn **Confirm email** back on, configure email delivery, and test confirmation, recovery, abuse controls, and expired/reused credentials.

### 2. Apply the database migration

Install the Supabase CLI using Supabase's current Windows instructions. Docker is not required to link and push migrations to a hosted project.

From the repository root, authenticate and link the production project:

```sh
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

The CLI may request the database password in the terminal. Enter it there; do not put it in source files. Inspect the migration plan/output and confirm the destination project reference before applying. Then run Supabase **Security Advisor** and check that every exposed table has the intended RLS policies.

### 3. Connect the Vercel Production deployment

In Vercel, open the project **Settings > Environment Variables** and add these for **Production**:

```text
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_STAGING_PUBLISHABLE_OR_ANON_KEY
```

Use the key field shown by Supabase. If it is a newer publishable key, it is still the client key consumed by `VITE_SUPABASE_ANON_KEY`. Never add a service-role key to Vercel frontend variables. Save and redeploy Production; environment changes apply to new deployments, not existing ones.

### 4. Verify the hosted integration

- Register one test consumer using an email address you control and a unique password.
- Sign out and sign back in; confirm the profile role remains `consumer`.
- Try selecting the other role for that same account; confirm the app rejects the mismatch.
- Register a test merchant; confirm its application is `pending` and it cannot reach merchant tools.
- In Supabase, confirm profile and merchant application rows exist and use Security Advisor/API checks to verify cross-user reads/writes are denied.
- Confirm checkout, payment, refund, payout, and fulfillment remain unavailable. They must stay disabled until server-side order transactions and provider integrations are implemented.

### 5. Enable public registration only after launch gates

The URL/key connection does not make commerce production-ready. This app still has no server-side order creation, inventory reservation, payment initiation/webhook verification, settlement, refund workflow, merchant-review console, or production delivery workflow. Before allowing public signup, re-enable email confirmation, configure recovery and abuse controls, review RLS/security, backups, privacy/legal obligations, payment/settlement, and operations. Do not accept real orders/payments until those workflows are implemented and tested.

Never add a Supabase `service_role` key, database password, or payment-provider secret to a `VITE_` variable. The publishable/anon key is intentionally public; Row Level Security is the access boundary.

## Current schema/security boundary

- A database trigger creates one profile per Supabase Auth user and fixes its account type as `consumer` or `merchant`.
- Email uniqueness is delegated to Supabase Auth; the database profile role is immutable for each authenticated identity.
- Merchant contact phone numbers collected during email/password signup are unverified contact details, not authentication factors.
- Merchant applications can only be submitted as `pending`. There is no client policy to approve, reject, or change verification status.
- Only verified merchants can expose offers or write offer changes. Product creation/moderation remains a trusted administrative operation.
- Customers and participating merchants can read only the order records allowed by the migration's RLS policies. Clients cannot insert or mutate orders, payments, payment-webhook events, refunds, shipments, or order events.
- `price_minor_units` is integer minor currency units (kobo for NGN); convert only at display boundaries and never use floating-point values for financial calculations.
- The existing demo cart and checkout are not connected to this schema. Do not accept real orders/payments until server-side checkout, inventory reservation, idempotency, verified provider webhooks, settlement rules, and reconciliation are implemented and tested.

## Local environment safety

`.env` and `.env.*` are ignored by Git; `.env.example` is the safe template. The Supabase publishable/anon client key may be exposed to the browser only because RLS is the access boundary. Never expose a service-role key, database password, SMS-provider secret, or payment-provider secret. If a secret is ever committed, rotate it in its provider even after removing it from Git history.
