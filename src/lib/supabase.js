import { createClient } from "@supabase/supabase-js";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL?.trim();
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim();

export const supabase = supabaseUrl && supabaseAnonKey
  ? createClient(supabaseUrl, supabaseAnonKey, {
      auth: {
        autoRefreshToken: true,
        detectSessionInUrl: true,
        persistSession: true,
      },
    })
  : null;

export const supabaseConfigured = Boolean(supabase);
export const demoMode = !supabaseConfigured && import.meta.env.DEV && import.meta.env.VITE_DEMO_MODE !== "false";

export function normalizeNigerianPhone(phone) {
  const digits = phone.replace(/\D/g, "");
  if (/^0\d{10}$/.test(digits)) return `+234${digits.slice(1)}`;
  if (/^234\d{10}$/.test(digits)) return `+${digits}`;
  if (/^\d{10}$/.test(digits)) return `+234${digits}`;
  return null;
}

export async function loadAccountProfile(userId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data: profile, error } = await supabase
    .from("profiles")
    .select("id, account_type, full_name, phone")
    .eq("id", userId)
    .single();
  if (error) throw error;

  const account = { id: profile.id, role: profile.account_type, name: profile.full_name, phone: profile.phone };
  if (profile.account_type !== "merchant") return { ...account, verificationStatus: "active" };

  const { data: merchant, error: merchantError } = await supabase
    .from("merchant_profiles")
    .select("store_name, market_name, stall_number, landmark, verification_status")
    .eq("user_id", profile.id)
    .maybeSingle();
  if (merchantError) throw merchantError;
  return {
    ...account,
    verificationStatus: merchant?.verification_status ?? "pending",
    application: merchant ? {
      stall: merchant.store_name,
      market: merchant.market_name,
      stallNumber: merchant.stall_number,
      landmark: merchant.landmark,
    } : null,
  };
}
