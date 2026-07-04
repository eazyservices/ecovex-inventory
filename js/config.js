// ---- CONFIGURE ONCE — used by every page ----
const SUPABASE_URL = "https://rppdpyvxobaozpgnybwz.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_HvpIyQY7BcEkAzn1uF-idw_hjQh3-3E";
// ----------------------------------------------

// `supabase` here is the global from the CDN script tag (must be loaded
// before this file in every page). We create our own client called `db`
// so page code never confuses the two.
const db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
