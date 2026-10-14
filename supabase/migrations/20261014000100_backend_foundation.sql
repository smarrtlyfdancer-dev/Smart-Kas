create extension if not exists pgcrypto with schema extensions;

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  account_type text not null check (account_type in ('consumer', 'merchant')),
  full_name text not null,
  phone text not null,
  created_at timestamptz not null default now()
);

create or replace function public.create_profile_for_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_type text;
begin
  requested_type := coalesce(new.raw_user_meta_data ->> 'account_type', 'consumer');
  if requested_type not in ('consumer', 'merchant') then
    raise exception 'Unsupported account type';
  end if;

  insert into public.profiles (id, account_type, full_name, phone)
  values (
    new.id,
    requested_type,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), 'Kasua member'),
    coalesce(new.phone, '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created_create_profile
after insert on auth.users
for each row execute function public.create_profile_for_auth_user();

insert into public.profiles (id, account_type, full_name, phone)
select
  id,
  case when raw_user_meta_data ->> 'account_type' = 'merchant' then 'merchant' else 'consumer' end,
  coalesce(nullif(trim(raw_user_meta_data ->> 'full_name'), ''), 'Kasua member'),
  coalesce(phone, '')
from auth.users
on conflict (id) do nothing;

create or replace function public.prevent_profile_role_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.account_type is distinct from old.account_type then
    raise exception 'Account type cannot be changed';
  end if;
  return new;
end;
$$;

create trigger profiles_account_type_is_immutable
before update on public.profiles
for each row execute function public.prevent_profile_role_change();

create table public.merchant_profiles (
  user_id uuid primary key references public.profiles (id) on delete restrict,
  store_name text not null check (length(trim(store_name)) between 2 and 120),
  market_name text not null check (length(trim(market_name)) between 2 and 120),
  stall_number text not null check (length(trim(stall_number)) between 1 and 40),
  landmark text not null check (length(trim(landmark)) between 2 and 240),
  verification_status text not null default 'pending'
    check (verification_status in ('pending', 'needs_changes', 'rejected', 'verified', 'suspended')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewer_user_id uuid references public.profiles (id) on delete set null,
  constraint merchant_review_fields_match_status check (
    (verification_status = 'pending' and reviewer_user_id is null and reviewed_at is null)
    or verification_status <> 'pending'
  )
);

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles (id) on delete cascade,
  label text not null,
  recipient_name text not null,
  phone text not null,
  address_line text not null,
  area text not null,
  landmark text,
  latitude double precision,
  longitude double precision,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  constraint address_latitude_valid check (latitude is null or latitude between -90 and 90),
  constraint address_longitude_valid check (longitude is null or longitude between -180 and 180)
);

create unique index one_default_address_per_customer
  on public.customer_addresses (customer_id)
  where is_default;

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.categories (id) on delete restrict,
  slug text not null unique,
  name text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0
);

insert into public.categories (slug, name, sort_order) values
  ('produce', 'Fresh produce', 10),
  ('grains', 'Grains & rice', 20),
  ('pantry', 'Pantry', 30),
  ('protein', 'Meat & fish', 40),
  ('household', 'Household', 50)
on conflict (slug) do nothing;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.categories (id) on delete restrict,
  name text not null,
  description text not null default '',
  attributes jsonb not null default '{}'::jsonb,
  variant_attributes jsonb not null default '{}'::jsonb,
  condition text not null default 'new'
    check (condition in ('new', 'used', 'refurbished', 'not_applicable')),
  status text not null default 'draft'
    check (status in ('draft', 'active', 'suspended', 'archived')),
  created_at timestamptz not null default now()
);

create table public.merchant_offers (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete restrict,
  merchant_user_id uuid not null references public.merchant_profiles (user_id) on delete restrict,
  merchant_sku text,
  price_minor_units bigint not null check (price_minor_units > 0),
  currency text not null default 'NGN' check (currency = 'NGN'),
  available_quantity integer not null default 0 check (available_quantity >= 0),
  is_active boolean not null default false,
  authenticity_notes text,
  return_terms text,
  delivery_estimate_minutes integer check (delivery_estimate_minutes is null or delivery_estimate_minutes >= 0),
  created_at timestamptz not null default now(),
  unique (merchant_user_id, merchant_sku)
);

create index merchant_offers_product_active_idx
  on public.merchant_offers (product_id, is_active)
  where is_active;

create table public.master_orders (
  id uuid primary key default gen_random_uuid(),
  public_reference text not null unique default (
    'SK-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))
  ),
  customer_id uuid not null references public.profiles (id) on delete restrict,
  idempotency_key text not null check (length(idempotency_key) between 16 and 200),
  status text not null default 'pending_payment'
    check (status in ('pending_payment', 'paid', 'processing', 'partially_fulfilled', 'fulfilled', 'cancelled', 'partially_refunded', 'refunded')),
  delivery_address_snapshot jsonb not null,
  currency text not null default 'NGN' check (currency = 'NGN'),
  subtotal_minor_units bigint not null check (subtotal_minor_units >= 0),
  delivery_fee_minor_units bigint not null default 0 check (delivery_fee_minor_units >= 0),
  service_fee_minor_units bigint not null default 0 check (service_fee_minor_units >= 0),
  discount_minor_units bigint not null default 0 check (discount_minor_units >= 0),
  total_minor_units bigint generated always as (
    subtotal_minor_units + delivery_fee_minor_units + service_fee_minor_units - discount_minor_units
  ) stored,
  allow_partial_fulfillment boolean not null default false,
  created_at timestamptz not null default now(),
  unique (customer_id, idempotency_key),
  check (discount_minor_units <= subtotal_minor_units + delivery_fee_minor_units + service_fee_minor_units)
);

create table public.merchant_suborders (
  id uuid primary key default gen_random_uuid(),
  master_order_id uuid not null references public.master_orders (id) on delete restrict,
  merchant_user_id uuid not null references public.merchant_profiles (user_id) on delete restrict,
  status text not null default 'awaiting_merchant'
    check (status in ('awaiting_merchant', 'accepted', 'rejected', 'preparing', 'at_hub', 'quality_check', 'ready_for_dispatch', 'in_transit', 'delivered', 'cancelled', 'delayed', 'failed_delivery')),
  subtotal_minor_units bigint not null check (subtotal_minor_units >= 0),
  delivery_fee_minor_units bigint not null default 0 check (delivery_fee_minor_units >= 0),
  accepted_at timestamptz,
  acceptance_deadline timestamptz,
  created_at timestamptz not null default now(),
  unique (master_order_id, merchant_user_id),
  unique (id, master_order_id)
);

create table public.order_lines (
  id uuid primary key default gen_random_uuid(),
  master_order_id uuid not null references public.master_orders (id) on delete restrict,
  merchant_suborder_id uuid not null,
  offer_id uuid references public.merchant_offers (id) on delete set null,
  product_snapshot jsonb not null,
  offer_snapshot jsonb not null,
  quantity_requested integer not null check (quantity_requested > 0),
  quantity_accepted integer not null default 0 check (quantity_accepted >= 0),
  quantity_shipped integer not null default 0 check (quantity_shipped >= 0),
  quantity_cancelled integer not null default 0 check (quantity_cancelled >= 0),
  unit_price_minor_units bigint not null check (unit_price_minor_units >= 0),
  currency text not null default 'NGN' check (currency = 'NGN'),
  created_at timestamptz not null default now(),
  foreign key (merchant_suborder_id, master_order_id)
    references public.merchant_suborders (id, master_order_id) on delete restrict,
  check (quantity_accepted <= quantity_requested),
  check (quantity_shipped + quantity_cancelled <= quantity_accepted)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  master_order_id uuid not null references public.master_orders (id) on delete restrict,
  customer_id uuid not null references public.profiles (id) on delete restrict,
  provider text not null check (provider in ('paystack', 'flutterwave', 'ussd', 'wallet')),
  provider_reference text,
  idempotency_key text not null unique,
  amount_minor_units bigint not null check (amount_minor_units > 0),
  currency text not null default 'NGN' check (currency = 'NGN'),
  status text not null default 'pending'
    check (status in ('pending', 'requires_action', 'authorized', 'captured', 'failed', 'cancelled', 'partially_refunded', 'refunded')),
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.payment_webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('paystack', 'flutterwave')),
  provider_event_id text not null,
  payload_digest text not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  processing_error text,
  unique (provider, provider_event_id)
);

create table public.shipments (
  id uuid primary key default gen_random_uuid(),
  merchant_suborder_id uuid not null references public.merchant_suborders (id) on delete restrict,
  status text not null default 'awaiting_collection'
    check (status in ('awaiting_collection', 'collected', 'at_hub', 'verified', 'packed', 'dispatched', 'in_transit', 'delivered', 'failed', 'returned')),
  carrier text,
  tracking_reference text,
  dispatched_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id) on delete restrict,
  master_order_id uuid not null references public.master_orders (id) on delete restrict,
  merchant_suborder_id uuid references public.merchant_suborders (id) on delete restrict,
  amount_minor_units bigint not null check (amount_minor_units > 0),
  currency text not null default 'NGN' check (currency = 'NGN'),
  reason text not null,
  status text not null default 'requested'
    check (status in ('requested', 'approved', 'processing', 'succeeded', 'failed', 'rejected')),
  provider_reference text,
  created_at timestamptz not null default now()
);

create table public.order_events (
  id uuid primary key default gen_random_uuid(),
  master_order_id uuid not null references public.master_orders (id) on delete restrict,
  merchant_suborder_id uuid references public.merchant_suborders (id) on delete restrict,
  actor_user_id uuid references public.profiles (id) on delete set null,
  event_type text not null,
  event_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index merchant_suborders_merchant_status_idx
  on public.merchant_suborders (merchant_user_id, status, created_at desc);
create index order_lines_master_order_idx on public.order_lines (master_order_id);
create index payments_order_status_idx on public.payments (master_order_id, status);
create index shipments_suborder_status_idx on public.shipments (merchant_suborder_id, status);
create index order_events_master_created_idx on public.order_events (master_order_id, created_at);

alter table public.profiles enable row level security;
alter table public.merchant_profiles enable row level security;
alter table public.customer_addresses enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.merchant_offers enable row level security;
alter table public.master_orders enable row level security;
alter table public.merchant_suborders enable row level security;
alter table public.order_lines enable row level security;
alter table public.payments enable row level security;
alter table public.payment_webhook_events enable row level security;
alter table public.shipments enable row level security;
alter table public.refunds enable row level security;
alter table public.order_events enable row level security;

create or replace function public.is_master_order_customer(target_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select exists (
    select 1 from public.master_orders o
    where o.id = target_order_id and o.customer_id = (select auth.uid())
  );
$$;

create or replace function public.is_suborder_merchant(target_suborder_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select exists (
    select 1 from public.merchant_suborders s
    where s.id = target_suborder_id and s.merchant_user_id = (select auth.uid())
  );
$$;

create or replace function public.is_suborder_customer(target_suborder_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select exists (
    select 1
    from public.merchant_suborders s
    join public.master_orders o on o.id = s.master_order_id
    where s.id = target_suborder_id and o.customer_id = (select auth.uid())
  );
$$;

revoke all on function public.is_master_order_customer(uuid) from public, anon;
revoke all on function public.is_suborder_merchant(uuid) from public, anon;
revoke all on function public.is_suborder_customer(uuid) from public, anon;
grant execute on function public.is_master_order_customer(uuid) to authenticated;
grant execute on function public.is_suborder_merchant(uuid) to authenticated;
grant execute on function public.is_suborder_customer(uuid) to authenticated;

create policy "profiles_select_own" on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy "profiles_update_own" on public.profiles
  for update to authenticated using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy "merchant_profiles_select_owner_or_verified" on public.merchant_profiles
  for select to anon, authenticated
  using (verification_status = 'verified' or user_id = (select auth.uid()));
create policy "merchant_profiles_submit_own_pending_application" on public.merchant_profiles
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and verification_status = 'pending'
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.account_type = 'merchant'
    )
  );

create policy "customer_addresses_manage_own" on public.customer_addresses
  for all to authenticated
  using (customer_id = (select auth.uid()))
  with check (
    customer_id = (select auth.uid())
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.account_type = 'consumer'
    )
  );

create policy "categories_read_active" on public.categories
  for select to anon, authenticated using (is_active);
create policy "products_read_active_offers" on public.products
  for select to anon, authenticated
  using (
    status = 'active'
    and exists (
      select 1
      from public.merchant_offers o
      join public.merchant_profiles m on m.user_id = o.merchant_user_id
      where o.product_id = products.id
        and o.is_active
        and o.available_quantity > 0
        and m.verification_status = 'verified'
    )
  );
create policy "offers_read_active_verified_or_owner" on public.merchant_offers
  for select to anon, authenticated
  using (
    (is_active and exists (
      select 1 from public.merchant_profiles m
      where m.user_id = merchant_offers.merchant_user_id
        and m.verification_status = 'verified'
    ))
    or merchant_user_id = (select auth.uid())
  );
create policy "offers_insert_verified_merchant" on public.merchant_offers
  for insert to authenticated
  with check (
    merchant_user_id = (select auth.uid())
    and exists (
      select 1 from public.merchant_profiles m
      where m.user_id = (select auth.uid()) and m.verification_status = 'verified'
    )
  );
create policy "offers_update_verified_owner" on public.merchant_offers
  for update to authenticated
  using (
    merchant_user_id = (select auth.uid())
    and exists (
      select 1 from public.merchant_profiles m
      where m.user_id = (select auth.uid()) and m.verification_status = 'verified'
    )
  )
  with check (merchant_user_id = (select auth.uid()));

create policy "master_orders_read_customer_or_merchant" on public.master_orders
  for select to authenticated
  using (customer_id = (select auth.uid()));
create policy "merchant_suborders_read_participant" on public.merchant_suborders
  for select to authenticated
  using (
    merchant_user_id = (select auth.uid())
    or public.is_master_order_customer(master_order_id)
  );
create policy "order_lines_read_participant" on public.order_lines
  for select to authenticated
  using (
    public.is_master_order_customer(master_order_id)
    or public.is_suborder_merchant(merchant_suborder_id)
  );
create policy "payments_read_customer" on public.payments
  for select to authenticated
  using (customer_id = (select auth.uid()));
create policy "shipments_read_participant" on public.shipments
  for select to authenticated
  using (
    public.is_suborder_merchant(merchant_suborder_id)
    or public.is_suborder_customer(merchant_suborder_id)
  );
create policy "refunds_read_customer" on public.refunds
  for select to authenticated
  using (
    exists (
      select 1 from public.master_orders o
      where o.id = refunds.master_order_id and o.customer_id = (select auth.uid())
    )
  );
create policy "order_events_read_participant" on public.order_events
  for select to authenticated
  using (
    exists (
      select 1 from public.master_orders o
      where o.id = order_events.master_order_id and o.customer_id = (select auth.uid())
    )
    or exists (
      select 1 from public.merchant_suborders s
      where s.id = order_events.merchant_suborder_id and s.merchant_user_id = (select auth.uid())
    )
  );

-- Orders, payments, refunds, webhooks, and event writes are intentionally server-only.
-- No authenticated/anonymous write policies are created for these records.
