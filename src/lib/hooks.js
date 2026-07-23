import { useState, useEffect } from "react";
import { supabase } from "./supabase.js";

/**
 * useSupabaseTable — fetch all rows from a table scoped to an agency
 * Usage: const { data, loading, error } = useSupabaseTable("tasks", agencyId)
 */
export function useSupabaseTable(tableName, agencyId, options = {}) {
  const { orderBy = "created_at", ascending = false, filters = [] } = options;
  const [data, setData] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!tableName) return;
    let cancelled = false;

    async function fetchData() {
      setLoading(true);
      setError(null);
      try {
        let query = supabase.from(tableName).select("*");

        // Apply agency scoping if agencyId exists and table likely has it
        if (agencyId) {
          query = query.eq("agency_id", agencyId);
        }

        // Apply any extra filters
        for (const { col, op, val } of filters) {
          query = query.filter(col, op, val);
        }

        if (orderBy) {
          query = query.order(orderBy, { ascending });
        }

        const { data: rows, error: err } = await query;
        if (cancelled) return;
        if (err) throw err;
        setData(rows || []);
      } catch (err) {
        if (!cancelled) setError(err.message || "Query failed");
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    fetchData();
    return () => { cancelled = true; };
  }, [tableName, agencyId, JSON.stringify(filters)]);

  return { data, loading, error, setData };
}

/**
 * useSupabaseQuery — run a custom Supabase query
 * Usage: const { data, loading } = useSupabaseQuery(() => supabase.from("<table>").select("<columns>"))
 */
export function useSupabaseQuery(queryFn, deps = []) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;
    async function run() {
      setLoading(true);
      setError(null);
      try {
        const { data: result, error: err } = await queryFn();
        if (cancelled) return;
        if (err) throw err;
        setData(result);
      } catch (err) {
        if (!cancelled) setError(err.message || "Query failed");
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    run();
    return () => { cancelled = true; };
  }, deps);

  return { data, loading, error };
}

/**
 * useViewport — responsive breakpoint hook used by NewtworksApp shell + modules.
 * Pixel 8 Pro ~412px wide portrait; iPad 10 ~820px portrait; 15" laptop ~1440px+.
 * Phone: <640. Tablet: 640-1023. Desktop: >=1024.
 *
 * Usage:
 *   import { useViewport } from "../lib/hooks.js";
 *   const { isPhone, isTablet, isDesktop, width } = useViewport();
 */
export function useViewport() {
  const compute = () => {
    if (typeof window === "undefined") {
      return { width: 1024, isPhone: false, isTablet: false, isDesktop: true };
    }
    const w = window.innerWidth;
    return {
      width: w,
      isPhone:   w < 640,
      isTablet:  w >= 640 && w < 1024,
      isDesktop: w >= 1024,
    };
  };
  const [vp, setVp] = useState(compute);
  useEffect(() => {
    const onResize = () => setVp(compute());
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);
  return vp;
}


// ─── useVerdictThresholds ─────────────────────────────────────
// Reads per-layer verdict cutoffs (pass / consider) from
// public.hiregauge_verdict_thresholds. Single source of truth
// shared with the verdict_overall RPC — updating
// the table row updates the frontend on next fetch.
//
// Module-level cache so multiple hook consumers share one fetch.
// Falls back to hardcoded values if fetch fails so the UI never
// breaks; fallback matches table seed values.
const FALLBACK_THRESHOLDS = {
  resume:     { pass: 70, consider: 50 },
  assessment: { pass: 75, consider: 60 },
  interview:  { pass: 75, consider: 60 },
  reference:  { pass: 75, consider: 60 },
  framework:  { pass: 75, consider: 60 },
};

let _thresholdsCache = null;
let _thresholdsPromise = null;

async function _loadVerdictThresholds() {
  if (_thresholdsCache) return _thresholdsCache;
  if (_thresholdsPromise) return _thresholdsPromise;
  _thresholdsPromise = (async () => {
    try {
      const { data, error } = await supabase
        .from("hiregauge_verdict_thresholds")
        .select("layer, pass_threshold, consider_threshold");
      if (error || !data || data.length === 0) return FALLBACK_THRESHOLDS;
      const m = { ...FALLBACK_THRESHOLDS };
      for (const r of data) {
        m[r.layer] = {
          pass: Number(r.pass_threshold),
          consider: Number(r.consider_threshold),
        };
      }
      _thresholdsCache = m;
      return m;
    } catch (e) {
      return FALLBACK_THRESHOLDS;
    }
  })();
  return _thresholdsPromise;
}

export function useVerdictThresholds() {
  const [t, setT] = useState(_thresholdsCache || FALLBACK_THRESHOLDS);
  useEffect(() => {
    if (_thresholdsCache) { setT(_thresholdsCache); return; }
    let mounted = true;
    _loadVerdictThresholds().then((v) => { if (mounted) setT(v); });
    return () => { mounted = false; };
  }, []);
  return t;
}
