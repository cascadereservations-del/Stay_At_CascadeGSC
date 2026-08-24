


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."apply_inventory_purchase"("p_item_id" "uuid", "p_qty" numeric, "p_unit_cost" numeric DEFAULT NULL::numeric, "p_supplier" "text" DEFAULT NULL::"text", "p_purchased_at" "date" DEFAULT CURRENT_DATE, "p_txn_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_upp numeric; v_before numeric; v_after numeric; v_pid uuid; v_name text;
begin
  select coalesce(units_per_purchase, 1), qty_on_hand, name
    into v_upp, v_before, v_name
  from inventory_items where id = p_item_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'item_not_found');
  end if;

  insert into inventory_purchases(item_id, qty, unit_cost, supplier, purchased_at, units_per_purchase, notes)
  values (p_item_id, p_qty, p_unit_cost, p_supplier, coalesce(p_purchased_at, current_date), v_upp,
          'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end)
  returning id into v_pid;

  v_after := coalesce(v_before, 0) + (p_qty * v_upp);
  update inventory_items set qty_on_hand = v_after where id = p_item_id;

  insert into inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  values ('inventory_items', p_item_id, 'ocr_restock',
          jsonb_build_object('qty_on_hand', v_before),
          jsonb_build_object('qty_on_hand', v_after, 'purchase_id', v_pid, 'qty_added', p_qty * v_upp),
          'telegram-ocr');

  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,
                            'qty_before', v_before, 'qty_after', v_after, 'added', p_qty * v_upp);
end; $$;


ALTER FUNCTION "public"."apply_inventory_purchase"("p_item_id" "uuid", "p_qty" numeric, "p_unit_cost" numeric, "p_supplier" "text", "p_purchased_at" "date", "p_txn_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."browse_kb"("filter_tags" "text"[] DEFAULT NULL::"text"[], "filter_applies_to" "text"[] DEFAULT NULL::"text"[], "max_results" integer DEFAULT 20) RETURNS TABLE("path" "text", "title" "text", "summary" "text", "tags" "text"[], "applies_to" "text"[], "doc_type" "text", "github_url" "text", "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select d.path, d.title, d.summary, d.tags, d.applies_to, d.doc_type, d.github_url, d.updated_at
  from public.kb_documents d
  where d.status = 'active'
    and (filter_tags       is null or d.tags       && filter_tags)
    and (filter_applies_to is null or d.applies_to && filter_applies_to)
  order by d.updated_at desc
  limit max_results;
$$;


ALTER FUNCTION "public"."browse_kb"("filter_tags" "text"[], "filter_applies_to" "text"[], "max_results" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_availability"("p_checkin" "date", "p_checkout" "date", "p_property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_conflicts jsonb;
BEGIN
  IF p_checkin IS NULL OR p_checkout IS NULL THEN
    RETURN jsonb_build_object('available', false, 'error', 'dates_required');
  END IF;
  IF p_checkin >= p_checkout THEN
    RETURN jsonb_build_object('available', false, 'error', 'checkin_must_be_before_checkout');
  END IF;
  IF p_checkin < CURRENT_DATE THEN
    RETURN jsonb_build_object('available', false, 'error', 'checkin_in_past');
  END IF;

  -- Overlap: existing event blocks if it starts before our checkout AND ends after our checkin.
  -- Checkout day of existing booking == our checkin day is allowed (back-to-back).
  SELECT jsonb_agg(jsonb_build_object(
    'checkin',   to_char(checkin_date,  'YYYY-MM-DD'),
    'checkout',  to_char(checkout_date, 'YYYY-MM-DD'),
    'summary',   COALESCE(raw_summary, 'Blocked')
  ))
  INTO v_conflicts
  FROM public.calendar_events
  WHERE property_id = p_property_id
    AND status NOT IN ('cancelled')
    AND checkin_date  < p_checkout
    AND checkout_date > p_checkin;

  IF v_conflicts IS NULL THEN
    RETURN jsonb_build_object('available', true, 'conflicts', '[]'::jsonb);
  ELSE
    RETURN jsonb_build_object('available', false, 'conflicts', v_conflicts);
  END IF;
END;
$$;


ALTER FUNCTION "public"."check_availability"("p_checkin" "date", "p_checkout" "date", "p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_income_transaction"("p_code" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_res    public.airbnb_reservations%ROWTYPE;
  v_result text := 'error:unknown';
BEGIN
  BEGIN
    -- Load reservation
    SELECT * INTO v_res
    FROM public.airbnb_reservations
    WHERE confirmation_code = p_code
    LIMIT 1;

    IF NOT FOUND THEN
      v_result := 'skip:no_reservation';

    ELSIF v_res.host_payout IS NULL OR v_res.host_payout = 0 THEN
      v_result := 'skip:no_payout';

    ELSIF v_res.checkout_date > CURRENT_DATE THEN
      v_result := 'skip:future_checkout';

    ELSE
      -- Coverage check (Option B canonical model):
      -- Path A: real payout email exists via detail_lines Home line
      -- Path B: synthetic confirmed row already created
      IF EXISTS (
        SELECT 1
        FROM public.airbnb_email_events e,
             jsonb_array_elements(e.raw_payload->'detail_lines') dl
        WHERE e.email_type              = 'payout'
          AND dl->>'line_type'          = 'Home'
          AND dl->>'confirmation_code'  = p_code
      ) OR EXISTS (
        SELECT 1
        FROM public.transactions t
        WHERE t.source       = 'airbnb_payout_email'
          AND t.income_stage = 'confirmed'
          AND t.status       = 'confirmed'
          AND t.external_ref = 'synthetic-' || p_code
      ) THEN
        v_result := 'exists:confirmed';

      ELSIF v_res.status != 'completed' THEN
        -- Cancelled or other non-completed status with no payout email coverage
        -- → no synthetic row should exist; void any that do (defensive)
        UPDATE public.transactions
        SET status = 'void', updated_at = now()
        WHERE external_ref = 'synthetic-' || p_code
          AND source = 'airbnb_payout_email'
          AND status IN ('pending_review','confirmed');
        v_result := 'skip:not_completed';

      ELSE
        -- Completed reservation, no payout email coverage → insert synthetic confirmed row
        INSERT INTO public.transactions (
          property_id, txn_type, category, status, source,
          income_stage, transaction_date, gross_amount, currency,
          payee_name, notes, external_ref
        ) VALUES (
          v_res.property_id,
          'income',
          'airbnb_income',
          'confirmed',
          'airbnb_payout_email',
          'confirmed',
          v_res.checkout_date + INTERVAL '1 day',
          v_res.host_payout::numeric,
          'PHP',
          'Airbnb',
          'synthetic — no payout email found · ' || p_code ||
          ' · ' || v_res.guest_name ||
          ' · checkout ' || v_res.checkout_date ||
          ' [auto-created ' || CURRENT_DATE || ']',
          'synthetic-' || p_code
        );
        v_result := 'fixed:inserted';
      END IF;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    v_result := 'error:' || SQLERRM;
  END;

  -- Log every call (non-fatal)
  BEGIN
    INSERT INTO public.reconciliation_log (confirmation_code, action, result)
    VALUES (p_code, 'ensure_income', v_result);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."ensure_income_transaction"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_direct_booking_cascade"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_prev_status text;
  v_url         text;
  v_token       text;
  v_bk          public.booking_inquiries%ROWTYPE;
  v_ref         text;
  v_nights      int;
BEGIN
  IF NEW.booking_id IS NULL THEN RETURN NEW; END IF;

  IF NEW.status = 'confirmed' AND OLD.status IS DISTINCT FROM 'confirmed' THEN
    SELECT status INTO v_prev_status FROM public.booking_inquiries WHERE id = NEW.booking_id;

    UPDATE public.booking_inquiries
       SET status = 'confirmed'
     WHERE id = NEW.booking_id AND status <> 'confirmed';

    UPDATE public.calendar_events
       SET status = 'confirmed'
     WHERE uid = 'direct:' || NEW.booking_id::text AND status <> 'confirmed';

    -- Dashboard/manual path (booking was still pending) -> send the guest email.
    IF v_prev_status IS DISTINCT FROM 'confirmed' THEN
      SELECT value INTO v_url   FROM public.app_secrets WHERE key = 'EMAIL_RELAY_URL';
      SELECT value INTO v_token FROM public.app_secrets WHERE key = 'EMAIL_RELAY_TOKEN';
      IF v_url IS NOT NULL AND v_token IS NOT NULL THEN
        SELECT * INTO v_bk FROM public.booking_inquiries WHERE id = NEW.booking_id;
        IF v_bk.guest_email IS NOT NULL AND v_bk.guest_email <> '' THEN
          v_ref    := upper(left(NEW.booking_id::text, 8));
          v_nights := (v_bk.checkout_date - v_bk.checkin_date);
          PERFORM net.http_post(
            url     := v_url,
            body    := jsonb_build_object(
                         'action',      'confirmEmail',
                         'token',       v_token,
                         'ref',         v_ref,
                         'guest_name',  v_bk.guest_name,
                         'guest_email', v_bk.guest_email,
                         'guest_phone', coalesce(v_bk.guest_phone, ''),
                         'checkin',     v_bk.checkin_date::text,
                         'checkout',    v_bk.checkout_date::text,
                         'nights',      v_nights,
                         'pax',         coalesce(v_bk.pax, 1),
                         'total',       coalesce(v_bk.total_amount, 0),
                         'deposit',     coalesce(v_bk.deposit_amount, 0),
                         'receipt_url', coalesce(v_bk.receipt_image_path, '')
                       ),
            headers := jsonb_build_object('Content-Type', 'application/json')
          );
        END IF;
      END IF;
    END IF;

  ELSIF NEW.status = 'void' AND OLD.status IS DISTINCT FROM 'void' THEN
    UPDATE public.booking_inquiries
       SET status = 'cancelled'
     WHERE id = NEW.booking_id AND status <> 'cancelled';
    UPDATE public.calendar_events
       SET status = 'cancelled'
     WHERE uid = 'direct:' || NEW.booking_id::text AND status <> 'cancelled';
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- never block the ledger update because of a cascade/email hiccup
  RAISE WARNING 'fn_direct_booking_cascade error: %', SQLERRM;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_direct_booking_cascade"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_active_staff"("p_property_id" "uuid") RETURNS TABLE("id" "uuid", "full_name" "text", "nickname" "text", "role" "text", "phone" "text", "photo_url" "text", "hire_date" "date", "employment_status" "text", "telegram_user_id" "text", "rate_override" numeric, "last_clean_date" timestamp with time zone, "total_cleans" bigint)
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT
    e.id,
    e.full_name,
    e.nickname,
    e.role,
    e.phone,
    e.photo_url,
    e.hire_date,
    e.employment_status,
    e.telegram_user_id,
    e.rate_override,
    MAX(cs.created_at) AS last_clean_date,
    COUNT(cs.id) AS total_cleans
  FROM public.employees e
  LEFT JOIN public.cleaning_sessions cs ON cs.employee_id = e.id
  WHERE e.property_id = p_property_id
    AND e.is_active = true
  GROUP BY e.id, e.full_name, e.nickname, e.role, e.phone, e.photo_url,
           e.hire_date, e.employment_status, e.telegram_user_id, e.rate_override
  ORDER BY e.full_name;
$$;


ALTER FUNCTION "public"."get_active_staff"("p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_booking_for_date"("p_date" "date", "p_property_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("event_id" "uuid", "checkin_date" "date", "checkout_date" "date", "nights" integer, "guest_name" "text", "source" "text", "status" "text", "match_type" "text")
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
BEGIN
  -- Post-checkout clean: guest checked out today (priority match)
  RETURN QUERY
  SELECT
    ce.id,
    ce.checkin_date,
    ce.checkout_date,
    ce.nights,
    ce.guest_name,
    ce.source,
    ce.status,
    'checkout'::text
  FROM public.calendar_events ce
  WHERE ce.checkout_date = p_date
    AND ce.status != 'cancelled'
    AND (p_property_id IS NULL OR ce.property_id = p_property_id)
  ORDER BY ce.synced_at DESC
  LIMIT 1;

  -- If no checkout match, try checkin (pre-arrival clean)
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      ce.id,
      ce.checkin_date,
      ce.checkout_date,
      ce.nights,
      ce.guest_name,
      ce.source,
      ce.status,
      'checkin'::text
    FROM public.calendar_events ce
    WHERE ce.checkin_date = p_date
      AND ce.status != 'cancelled'
      AND (p_property_id IS NULL OR ce.property_id = p_property_id)
    ORDER BY ce.synced_at DESC
    LIMIT 1;
  END IF;
END;
$$;


ALTER FUNCTION "public"."get_booking_for_date"("p_date" "date", "p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_data_integrity_report"("p_property_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_txn_dupe_groups int := 0;
  v_txn_dupe_rows   jsonb := '[]'::jsonb;
  v_txn_no_cat      int := 0;
  v_txn_no_payee    int := 0;
  v_meter_negative  jsonb := '[]'::jsonb;
  v_meter_neg_count int := 0;
  v_meter_spike     jsonb := '[]'::jsonb;
  v_meter_spike_cnt int := 0;
  v_e_median numeric;
  v_w_median numeric;
  v_resv_missing  int := 0;
  v_resv_mismatch int := 0;
  v_issues_total  int := 0;
BEGIN
  -- TRANSACTIONS: duplicate detection among non-void rows
  WITH g AS (
    SELECT transaction_date, gross_amount, COALESCE(payee_name,'') AS payee, txn_type,
           COUNT(*) AS n, jsonb_agg(id ORDER BY created_at) AS ids
    FROM public.transactions
    WHERE property_id = p_property_id AND status <> 'void'
    GROUP BY transaction_date, gross_amount, COALESCE(payee_name,''), txn_type
    HAVING COUNT(*) > 1
  )
  SELECT COUNT(*),
         COALESCE(jsonb_agg(jsonb_build_object(
           'date', transaction_date, 'amount', gross_amount,
           'payee', payee, 'type', txn_type, 'count', n, 'ids', ids
         ) ORDER BY n DESC), '[]'::jsonb)
  INTO v_txn_dupe_groups, v_txn_dupe_rows FROM g;

  SELECT COUNT(*) INTO v_txn_no_cat
  FROM public.transactions
  WHERE property_id = p_property_id AND status = 'confirmed' AND txn_type = 'expense'
    AND (category IS NULL OR category = '');

  SELECT COUNT(*) INTO v_txn_no_payee
  FROM public.transactions
  WHERE property_id = p_property_id AND status = 'confirmed' AND txn_type = 'expense'
    AND (payee_name IS NULL OR payee_name = '');

  -- METERS: negative deltas (meter ran backward / typo)
  SELECT COUNT(*),
         COALESCE(jsonb_agg(jsonb_build_object(
           'session_id', session_id, 'recorded_at', recorded_at,
           'electric_prev', electric_prev, 'electric_curr', electric_curr, 'electric_delta', electric_delta,
           'water_prev', water_prev, 'water_curr', water_curr, 'water_delta', water_delta
         ) ORDER BY recorded_at DESC), '[]'::jsonb)
  INTO v_meter_neg_count, v_meter_negative
  FROM public.meter_readings
  WHERE property_id = p_property_id AND (electric_delta < 0 OR water_delta < 0);

  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY electric_delta)
  INTO v_e_median FROM public.meter_readings
  WHERE property_id = p_property_id AND electric_delta > 0;

  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY water_delta)
  INTO v_w_median FROM public.meter_readings
  WHERE property_id = p_property_id AND water_delta > 0;

  -- METERS: spikes greater than 3x the median delta
  SELECT COUNT(*),
         COALESCE(jsonb_agg(jsonb_build_object(
           'session_id', session_id, 'recorded_at', recorded_at,
           'electric_delta', electric_delta, 'electric_median', ROUND(v_e_median, 2),
           'water_delta', water_delta, 'water_median', ROUND(v_w_median, 2)
         ) ORDER BY recorded_at DESC), '[]'::jsonb)
  INTO v_meter_spike_cnt, v_meter_spike
  FROM public.meter_readings
  WHERE property_id = p_property_id
    AND (
      (v_e_median IS NOT NULL AND v_e_median > 0 AND electric_delta > v_e_median * 3) OR
      (v_w_median IS NOT NULL AND v_w_median > 0 AND water_delta   > v_w_median * 3)
    );

  -- RESERVATIONS: payout reconciliation (mirrors get_datahealth_report)
  SELECT COUNT(*) INTO v_resv_missing
  FROM public.airbnb_reservations
  WHERE property_id = p_property_id AND status <> 'cancelled'
    AND checkout_date < CURRENT_DATE AND payout_date IS NULL AND payout_amount IS NULL;

  SELECT COUNT(*) INTO v_resv_mismatch
  FROM public.airbnb_reservations
  WHERE property_id = p_property_id AND status <> 'cancelled'
    AND checkout_date < CURRENT_DATE
    AND host_payout IS NOT NULL AND payout_amount IS NOT NULL
    AND ABS(host_payout - payout_amount) > 100;

  v_issues_total := v_txn_dupe_groups + v_txn_no_cat + v_txn_no_payee
                  + v_meter_neg_count + v_meter_spike_cnt
                  + v_resv_missing + v_resv_mismatch;

  RETURN jsonb_build_object(
    'generated_at', now(),
    'issues_total', v_issues_total,
    'status', CASE
                WHEN v_issues_total = 0 THEN 'ok'
                WHEN (v_txn_dupe_groups + v_meter_neg_count + v_resv_mismatch) > 0 THEN 'critical'
                ELSE 'warn'
              END,
    'transactions', jsonb_build_object(
      'duplicate_groups', v_txn_dupe_groups,
      'duplicate_detail', v_txn_dupe_rows,
      'missing_category', v_txn_no_cat,
      'missing_payee', v_txn_no_payee
    ),
    'meters', jsonb_build_object(
      'negative_delta_count', v_meter_neg_count,
      'negative_detail', v_meter_negative,
      'spike_count', v_meter_spike_cnt,
      'spike_detail', v_meter_spike,
      'electric_median', ROUND(COALESCE(v_e_median, 0), 2),
      'water_median', ROUND(COALESCE(v_w_median, 0), 2)
    ),
    'reservations', jsonb_build_object(
      'payout_missing', v_resv_missing,
      'mismatch_over_100', v_resv_mismatch
    )
  );
END;
$$;


ALTER FUNCTION "public"."get_data_integrity_report"("p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_datahealth_report"("p_property_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_total          int := 0;
  v_reconciled     int := 0;
  v_missing_count  int := 0;
  v_missing_rows   jsonb := '[]'::jsonb;
  v_mismatch_count int := 0;
  v_mismatch_rows  jsonb := '[]'::jsonb;
BEGIN
  SELECT COUNT(*)
  INTO v_total
  FROM public.airbnb_reservations
  WHERE property_id = p_property_id
    AND status <> 'cancelled'
    AND checkout_date < CURRENT_DATE;

  SELECT COUNT(*)
  INTO v_reconciled
  FROM public.airbnb_reservations
  WHERE property_id = p_property_id
    AND status <> 'cancelled'
    AND checkout_date < CURRENT_DATE
    AND payout_date IS NOT NULL
    AND payout_amount IS NOT NULL;

  SELECT
    COUNT(*),
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'code',     confirmation_code,
          'checkout', checkout_date,
          'guest',    COALESCE(guest_name, 'Unknown')
        ) ORDER BY checkout_date DESC
      ),
      '[]'::jsonb
    )
  INTO v_missing_count, v_missing_rows
  FROM public.airbnb_reservations
  WHERE property_id = p_property_id
    AND status <> 'cancelled'
    AND checkout_date < CURRENT_DATE
    AND payout_date IS NULL
    AND payout_amount IS NULL;

  SELECT
    COUNT(*),
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'code',       confirmation_code,
          'checkout',   checkout_date,
          'guest',      COALESCE(guest_name, 'Unknown'),
          'email_est',  host_payout,
          'csv_payout', payout_amount,
          'delta',      ROUND(ABS(host_payout - payout_amount)::numeric, 2)
        ) ORDER BY ABS(host_payout - payout_amount) DESC
      ),
      '[]'::jsonb
    )
  INTO v_mismatch_count, v_mismatch_rows
  FROM public.airbnb_reservations
  WHERE property_id = p_property_id
    AND status <> 'cancelled'
    AND checkout_date < CURRENT_DATE
    AND host_payout IS NOT NULL
    AND payout_amount IS NOT NULL
    AND ABS(host_payout - payout_amount) > 100;

  RETURN jsonb_build_object(
    'total_checked',   v_total,
    'reconciled',      v_reconciled,
    'payout_missing',  v_missing_count,
    'missing_rows',    v_missing_rows,
    'mismatch_count',  v_mismatch_count,
    'mismatch_rows',   v_mismatch_rows
  );
END;
$$;


ALTER FUNCTION "public"."get_datahealth_report"("p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_employee_history"("p_employee_id" "uuid") RETURNS TABLE("session_id" "uuid", "session_date" timestamp with time zone, "cleaning_type" "text", "cleaner_name" "text", "fee_amount" numeric, "fee_paid_at" timestamp with time zone, "notes" "text", "effective_rate" numeric, "pay_period" "text")
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT
    cs.id AS session_id,
    cs.created_at AS session_date,
    cs.cleaning_type,
    cs.cleaner_name,
    cs.fee_amount,
    cs.fee_paid_at,
    cs.notes,
    COALESCE(
      e.rate_override,
      (SELECT
         CASE WHEN cs.cleaning_type = 'general' THEN crs.general_rate
              ELSE crs.regular_rate
         END
       FROM public.cleaner_rate_schedule crs
       WHERE crs.effective_from <= cs.created_at::date
         AND crs.property_id = e.property_id
       ORDER BY crs.effective_from DESC LIMIT 1)
    ) AS effective_rate,
    to_char(cs.created_at, 'YYYY-MM') AS pay_period
  FROM public.cleaning_sessions cs
  JOIN public.employees e ON e.id = cs.employee_id
  WHERE cs.employee_id = p_employee_id
  ORDER BY cs.created_at DESC;
$$;


ALTER FUNCTION "public"."get_employee_history"("p_employee_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_finance_summary"("p_month" "date" DEFAULT (("now"() AT TIME ZONE 'Asia/Manila'::"text"))::"date", "p_property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  with bounds as (
    select date_trunc('month', p_month)::date as m_start,
           (date_trunc('month', p_month) + interval '1 month')::date as m_next
  ),
  scoped as (
    select t.txn_type, t.category, t.gross_amount
    from public.transactions t, bounds b
    where t.property_id = p_property_id
      and t.status = 'confirmed'
      and t.transaction_date >= b.m_start
      and t.transaction_date <  b.m_next
  ),
  totals as (
    select
      coalesce(sum(gross_amount) filter (where txn_type = 'income'),  0) as income,
      coalesce(sum(gross_amount) filter (where txn_type = 'expense'), 0) as expenses
    from scoped
  ),
  by_cat as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'category', x.category,
             'label',    coalesce(ec.label, initcap(replace(x.category,'_',' '))),
             'txn_type', x.txn_type,
             'total',    x.total,
             'count',    x.cnt
           ) order by x.total desc), '[]'::jsonb) as rows
    from (
      select txn_type, category, sum(gross_amount) as total, count(*) as cnt
      from scoped group by txn_type, category
    ) x
    left join public.expense_categories ec
      on ec.slug = x.category and ec.property_id = p_property_id
  ),
  pending as (
    select count(*) as cnt
    from public.transactions t, bounds b
    where t.property_id = p_property_id
      and t.status = 'pending_review'
      and t.transaction_date >= b.m_start
      and t.transaction_date <  b.m_next
  )
  select jsonb_build_object(
    'month',          to_char((select m_start from bounds), 'YYYY-MM'),
    'property_id',    p_property_id,
    'currency',       'PHP',
    'income',         (select income   from totals),
    'expenses',       (select expenses from totals),
    'net',            (select income - expenses from totals),
    'by_category',    (select rows from by_cat),
    'pending_review', (select cnt from pending)
  );
$$;


ALTER FUNCTION "public"."get_finance_summary"("p_month" "date", "p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_guest_history"("p_full_name" "text", "p_property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_first      text;
  v_count      int  := 0;
  v_nights_sum int  := 0;
  v_last       record;
BEGIN
  v_first := trim(split_part(trim(p_full_name), ' ', 1));

  -- Count past completed stays matching this guest (full name preferred, first name fallback)
  SELECT COUNT(*), COALESCE(SUM(r.nights), 0)
  INTO v_count, v_nights_sum
  FROM public.airbnb_reservations r
  WHERE r.property_id = p_property_id
    AND r.status IN ('completed', 'confirmed')
    AND r.checkout_date < CURRENT_DATE
    AND (
      lower(r.guest_name) = lower(p_full_name)
      OR lower(r.guest_name) LIKE lower(v_first) || ' %'
      OR lower(r.guest_name) LIKE '% ' || lower(v_first)
    );

  -- Most recent completed stay
  SELECT r.checkin_date, r.checkout_date, r.nights, r.guest_name
  INTO v_last
  FROM public.airbnb_reservations r
  WHERE r.property_id = p_property_id
    AND r.status IN ('completed', 'confirmed')
    AND r.checkout_date < CURRENT_DATE
    AND (
      lower(r.guest_name) = lower(p_full_name)
      OR lower(r.guest_name) LIKE lower(v_first) || ' %'
    )
  ORDER BY r.checkout_date DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'is_returning',   v_count > 0,
    'previous_stays', v_count,
    'total_stays',    v_count + 1,   -- includes current stay
    'total_nights',   v_nights_sum,
    'last_stay', CASE WHEN v_last IS NOT NULL THEN jsonb_build_object(
      'checkin',  v_last.checkin_date,
      'checkout', v_last.checkout_date,
      'nights',   v_last.nights
    ) ELSE NULL END
  );
END;
$$;


ALTER FUNCTION "public"."get_guest_history"("p_full_name" "text", "p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_kb_document"("p_path" "text") RETURNS TABLE("path" "text", "title" "text", "content" "text", "tags" "text"[], "applies_to" "text"[], "triggers" "text"[], "doc_type" "text", "github_url" "text", "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select d.path, d.title, d.content, d.tags, d.applies_to, d.triggers, d.doc_type, d.github_url, d.updated_at
  from public.kb_documents d
  where d.path = p_path and d.status = 'active';
$$;


ALTER FUNCTION "public"."get_kb_document"("p_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_missed_cleanings"("p_property_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("confirmation_code" "text", "guest_name" "text", "checkin_date" "date", "checkout_date" "date", "reservation_status" "text")
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_yesterday date;
  v_prop_id   uuid;
BEGIN
  -- 00:00 UTC cron = 08:00 Manila; yesterday Manila = CURRENT_DATE - 1 (UTC)
  v_yesterday := CURRENT_DATE - 1;
  v_prop_id   := COALESCE(p_property_id, (SELECT id FROM public.properties LIMIT 1));

  RETURN QUERY
  SELECT
    ar.confirmation_code,
    ar.guest_name,
    ar.checkin_date,
    ar.checkout_date,
    ar.status
  FROM public.airbnb_reservations ar
  WHERE ar.property_id = v_prop_id
    AND ar.checkout_date = v_yesterday
    AND ar.status NOT IN ('cancelled', 'inquiry', 'request')
    AND NOT EXISTS (
      SELECT 1
      FROM public.cleaning_sessions cs
      WHERE cs.property_id = v_prop_id
        AND (
          cs.checkout_date = ar.checkout_date
          OR cs.cleaned_at::date = v_yesterday
        )
    );
END;
$$;


ALTER FUNCTION "public"."get_missed_cleanings"("p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_usage_medians"() RETURNS TABLE("item_id" "uuid", "median_used" numeric)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select item_id,
         percentile_cont(0.5) within group (order by used_qty)::numeric(10,2)
  from inventory_usage
  where session_date >= current_date - interval '90 days'
  group by item_id;
$$;


ALTER FUNCTION "public"."get_usage_medians"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_welcome_info"("p_date" "date" DEFAULT CURRENT_DATE, "p_property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_cal       record;
  v_res       record;
  v_first     text;
  v_last      text;
  v_full_name text;
BEGIN
  SELECT guest_name, raw_summary, checkin_date, checkout_date, nights, checkin_time, checkout_time
  INTO v_cal
  FROM public.calendar_events
  WHERE property_id   = p_property_id
    AND status        = 'confirmed'
    AND checkin_date <= p_date
    AND checkout_date > p_date
  ORDER BY checkin_date DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  IF v_cal.guest_name IS NOT NULL AND trim(v_cal.guest_name) <> '' THEN
    v_full_name := trim(v_cal.guest_name);
  ELSE
    SELECT guest_name INTO v_res
    FROM public.airbnb_reservations
    WHERE property_id  = p_property_id
      AND status       NOT IN ('cancelled')
      AND checkin_date BETWEEN v_cal.checkin_date - 2 AND v_cal.checkin_date + 2
    ORDER BY ABS(checkin_date - v_cal.checkin_date) ASC, created_at DESC
    LIMIT 1;
    v_full_name := CASE
      WHEN v_res.guest_name IS NOT NULL AND trim(v_res.guest_name) <> ''
        THEN trim(v_res.guest_name)
      ELSE coalesce(nullif(trim(v_cal.raw_summary), ''), 'Guest')
    END;
  END IF;

  v_first := trim(split_part(v_full_name, ' ', 1));
  v_last  := trim(split_part(v_full_name, ' ', 2));
  IF lower(v_first) IN ('reserved', 'airbnb', 'not', '') THEN
    v_first := 'Guest'; v_last := null;
  END IF;

  RETURN jsonb_build_object(
    'found',         true,
    'first_name',    v_first,
    'last_name',     nullif(v_last, ''),
    'full_name',     v_full_name,
    'checkin_date',  v_cal.checkin_date,
    'checkout_date', v_cal.checkout_date,
    'nights',        v_cal.nights,
    'checkin_time',  v_cal.checkin_time,
    'checkout_time', v_cal.checkout_time
  );
END;
$$;


ALTER FUNCTION "public"."get_welcome_info"("p_date" "date", "p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."kb_documents_update_fts"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  new.fts :=
    setweight(to_tsvector('english'::regconfig, coalesce(new.title, '')),                                'A') ||
    setweight(to_tsvector('english'::regconfig, array_to_string(coalesce(new.tags, '{}'),       ' ')),   'B') ||
    setweight(to_tsvector('english'::regconfig, array_to_string(coalesce(new.triggers, '{}'),   ' ')),   'B') ||
    setweight(to_tsvector('english'::regconfig, array_to_string(coalesce(new.applies_to, '{}'), ' ')),   'B') ||
    setweight(to_tsvector('english'::regconfig, coalesce(new.summary, '')),                              'B') ||
    setweight(to_tsvector('english'::regconfig, coalesce(new.content, '')),                              'C');
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."kb_documents_update_fts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_returning_guest_alert"("p_guest_name" "text", "p_current_checkin" "date", "p_current_checkout" "date", "p_current_nights" integer, "p_previous_stays" integer, "p_total_nights" integer, "p_last_stay_checkin" "date" DEFAULT NULL::"date", "p_last_stay_checkout" "date" DEFAULT NULL::"date", "p_property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_id        uuid;
  v_bot_token text;
  v_chat_id   text;
  v_ordinal   text;
  v_msg       text;
BEGIN
  -- Insert log record
  INSERT INTO public.returning_guest_alerts (
    property_id, guest_name,
    current_checkin, current_checkout, current_nights,
    previous_stays, total_nights,
    last_stay_checkin, last_stay_checkout
  ) VALUES (
    p_property_id, p_guest_name,
    p_current_checkin, p_current_checkout, p_current_nights,
    p_previous_stays, p_total_nights,
    p_last_stay_checkin, p_last_stay_checkout
  ) RETURNING id INTO v_id;

  -- Read Telegram credentials from app_settings
  SELECT (value #>> '{}') INTO v_bot_token
  FROM public.app_settings WHERE key = 'telegram_bot_token';

  SELECT (value #>> '{}') INTO v_chat_id
  FROM public.app_settings WHERE key = 'telegram_marifel_chat_id';

  -- Only fire if credentials are configured (not placeholder)
  IF v_bot_token IS NULL OR v_bot_token LIKE '%PASTE%'
  OR v_chat_id  IS NULL OR v_chat_id  LIKE '%PASTE%' THEN
    RETURN v_id;  -- logged but not sent yet
  END IF;

  -- Ordinal suffix
  v_ordinal := CASE (p_previous_stays + 1)
    WHEN 1 THEN '1st' WHEN 2 THEN '2nd' WHEN 3 THEN '3rd'
    ELSE (p_previous_stays + 1)::text || 'th'
  END;

  -- Build Telegram message
  v_msg :=
    '🔔 *Returning Guest Alert*' || E'\n\n' ||
    '👤 *' || p_guest_name || '*' || E'\n' ||
    '📅 ' || to_char(p_current_checkin,  'Mon DD') || ' → ' ||
             to_char(p_current_checkout, 'Mon DD, YYYY') ||
             ' (' || p_current_nights || ' night' || CASE WHEN p_current_nights = 1 THEN '' ELSE 's' END || ')' || E'\n' ||
    '🏠 Visit *' || v_ordinal || '* at Cascade Hideaway' || E'\n\n' ||
    '📊 *Guest History*' || E'\n' ||
    '• Previous stays: ' || p_previous_stays || E'\n' ||
    '• Total nights stayed: ' || p_total_nights ||
    CASE WHEN p_last_stay_checkin IS NOT NULL THEN
      E'\n• Last visit: ' || to_char(p_last_stay_checkin, 'Mon DD') ||
      ' → ' || to_char(p_last_stay_checkout, 'Mon DD, YYYY')
    ELSE '' END ||
    E'\n\n' ||
    '_Verified via Welcome Guide_ ✓';

  -- Async HTTP call to Telegram (pg_net — non-blocking)
  PERFORM net.http_post(
    url     := 'https://api.telegram.org/bot' || v_bot_token || '/sendMessage',
    body    := jsonb_build_object(
                 'chat_id',    v_chat_id,
                 'text',       v_msg,
                 'parse_mode', 'Markdown'
               ),
    headers := '{"Content-Type":"application/json"}'::jsonb
  );

  UPDATE public.returning_guest_alerts
  SET telegram_sent = true, telegram_sent_at = now()
  WHERE id = v_id;

  RETURN v_id;
END;
$$;


ALTER FUNCTION "public"."log_returning_guest_alert"("p_guest_name" "text", "p_current_checkin" "date", "p_current_checkout" "date", "p_current_nights" integer, "p_previous_stays" integer, "p_total_nights" integer, "p_last_stay_checkin" "date", "p_last_stay_checkout" "date", "p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_inventory_item"("p_name" "text", "p_limit" integer DEFAULT 1, "p_threshold" real DEFAULT 0.3, "p_consumable_only" boolean DEFAULT true) RETURNS TABLE("id" "uuid", "name" "text", "category" "text", "is_consumable" boolean, "units_per_purchase" numeric, "qty_on_hand" numeric, "score" real)
    LANGUAGE "sql" STABLE
    AS $$
  select i.id, i.name, i.category, i.is_consumable,
         coalesce(i.units_per_purchase, 1) as units_per_purchase,
         i.qty_on_hand,
         greatest(similarity(i.name, p_name), word_similarity(i.name, p_name)) as score
  from inventory_items i
  where i.is_active
    and (not p_consumable_only or i.is_consumable)
    and greatest(similarity(i.name, p_name), word_similarity(i.name, p_name)) >= p_threshold
  order by score desc, i.is_consumable desc
  limit greatest(p_limit, 1);
$$;


ALTER FUNCTION "public"."match_inventory_item"("p_name" "text", "p_limit" integer, "p_threshold" real, "p_consumable_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reconcile_all_completed_reservations"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_code  TEXT;
  v_total INTEGER := 0;
  v_ok    INTEGER := 0;
  v_skip  INTEGER := 0;
  v_result JSONB;
BEGIN
  FOR v_code IN
    SELECT DISTINCT confirmation_code
    FROM public.airbnb_reservations
    WHERE status = 'completed'
      AND confirmation_code IS NOT NULL
    ORDER BY confirmation_code
  LOOP
    v_result := public.reconcile_reservation_from_transactions(v_code);
    v_total := v_total + 1;
    IF (v_result->>'skipped')::boolean THEN
      v_skip := v_skip + 1;
    ELSE
      v_ok := v_ok + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('total', v_total, 'reconciled', v_ok, 'skipped', v_skip);
END;
$$;


ALTER FUNCTION "public"."reconcile_all_completed_reservations"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reconcile_reservation_from_transactions"("p_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_host_payout   NUMERIC;
  v_guest_paid    NUMERIC;
  v_checkout_date DATE;
  v_checkin_date  DATE;
  v_res_status    TEXT;
  v_changed       BOOLEAN := false;
BEGIN
  -- Only proceed if this code has transaction rows
  IF NOT EXISTS (
    SELECT 1 FROM public.airbnb_transactions
    WHERE confirmation_code = p_code AND row_type IN ('reservation','adjustment')
  ) THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'no_transactions');
  END IF;

  -- Net host payout = sum of reservation amounts + any adjustments (adjustments are signed)
  SELECT
    SUM(amount),
    MAX(end_date),
    MIN(start_date)
  INTO v_host_payout, v_checkout_date, v_checkin_date
  FROM public.airbnb_transactions
  WHERE confirmation_code = p_code
    AND row_type IN ('reservation', 'adjustment');

  -- Guest paid = sum of gross_earnings from reservation rows only
  SELECT SUM(gross_earnings)
  INTO v_guest_paid
  FROM public.airbnb_transactions
  WHERE confirmation_code = p_code AND row_type = 'reservation';

  -- Get current status to decide if date reconciliation applies
  SELECT status INTO v_res_status
  FROM public.airbnb_reservations
  WHERE confirmation_code = p_code;

  IF v_res_status IS NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'reservation_not_found');
  END IF;

  -- For COMPLETED bookings: reconcile financials AND dates (stay is over, CSV is ground truth)
  -- For CONFIRMED bookings: reconcile financials only (stay is future, email dates more current)
  -- For CANCELLED: never touch
  IF v_res_status = 'cancelled' THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'cancelled');
  END IF;

  IF v_res_status = 'completed' THEN
    UPDATE public.airbnb_reservations SET
      host_payout    = COALESCE(v_host_payout, host_payout),
      payout_amount  = COALESCE(v_host_payout, payout_amount),
      guest_paid     = COALESCE(v_guest_paid, guest_paid),
      checkin_date   = COALESCE(v_checkin_date, checkin_date),
      checkout_date  = COALESCE(v_checkout_date, checkout_date),
      updated_at     = now()
    WHERE confirmation_code = p_code;
  ELSE
    -- Confirmed/upcoming: financials only, dates stay from email
    UPDATE public.airbnb_reservations SET
      host_payout    = COALESCE(v_host_payout, host_payout),
      payout_amount  = COALESCE(v_host_payout, payout_amount),
      guest_paid     = COALESCE(v_guest_paid, guest_paid),
      updated_at     = now()
    WHERE confirmation_code = p_code;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'code', p_code,
    'status', v_res_status,
    'host_payout', v_host_payout,
    'guest_paid', v_guest_paid,
    'checkout_date', v_checkout_date
  );
END;
$$;


ALTER FUNCTION "public"."reconcile_reservation_from_transactions"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_guest_stats"("p_guest_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_stays  INTEGER;
  v_nights INTEGER;
  v_first  DATE;
  v_last   DATE;
  v_tier   TEXT;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE status IN ('completed','confirmed')),
    COALESCE(SUM(nights) FILTER (WHERE status = 'completed'), 0),
    MIN(checkin_date) FILTER (WHERE status IN ('completed','confirmed')),
    MAX(checkin_date) FILTER (WHERE status IN ('completed','confirmed'))
  INTO v_stays, v_nights, v_first, v_last
  FROM public.airbnb_reservations
  WHERE guest_id = p_guest_id;

  v_tier := CASE
    WHEN v_stays >= 4 OR v_nights >= 10 THEN 'vip'
    WHEN v_stays >= 2 THEN 'returning'
    ELSE NULL
  END;

  UPDATE public.guests SET
    total_stays = v_stays,
    total_nights_stayed = v_nights,
    first_stay_date = v_first,
    last_stay_date = v_last,
    tier = v_tier,
    updated_at = now()
  WHERE id = p_guest_id;
END;
$$;


ALTER FUNCTION "public"."refresh_guest_stats"("p_guest_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_kb"("query_text" "text", "max_results" integer DEFAULT 5, "filter_tags" "text"[] DEFAULT NULL::"text"[], "filter_applies_to" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("path" "text", "title" "text", "summary" "text", "tags" "text"[], "applies_to" "text"[], "doc_type" "text", "github_url" "text", "rank" real)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select d.path, d.title, d.summary, d.tags, d.applies_to, d.doc_type, d.github_url,
         ts_rank(d.fts, websearch_to_tsquery('english', query_text))::real as rank
  from public.kb_documents d
  where d.status = 'active'
    and d.fts @@ websearch_to_tsquery('english', query_text)
    and (filter_tags       is null or d.tags       && filter_tags)
    and (filter_applies_to is null or d.applies_to && filter_applies_to)
  order by rank desc
  limit max_results;
$$;


ALTER FUNCTION "public"."search_kb"("query_text" "text", "max_results" integer, "filter_tags" "text"[], "filter_applies_to" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_kb_full"("query_text" "text", "max_results" integer DEFAULT 3) RETURNS TABLE("path" "text", "title" "text", "content" "text", "rank" real)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select d.path, d.title, d.content,
         ts_rank(d.fts, websearch_to_tsquery('english', query_text))::real as rank
  from public.kb_documents d
  where d.status = 'active'
    and d.fts @@ websearch_to_tsquery('english', query_text)
  order by rank desc
  limit max_results;
$$;


ALTER FUNCTION "public"."search_kb_full"("query_text" "text", "max_results" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_csv_row_reconcile"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.confirmation_code IS NOT NULL THEN
    PERFORM public.ensure_income_transaction(NEW.confirmation_code);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_csv_row_reconcile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fn_reservation_cancel_sync"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  -- Only fire when status actually transitions to cancelled
  IF NEW.status = 'cancelled' AND (OLD.status IS DISTINCT FROM 'cancelled') THEN

    -- 3a: Propagate cancelled status to matching calendar_events row
    UPDATE public.calendar_events
    SET    status     = 'cancelled',
           updated_at = now()
    WHERE  property_id   = NEW.property_id
      AND  checkin_date  = NEW.checkin_date
      AND  checkout_date = NEW.checkout_date
      AND  status       != 'cancelled';

    -- 3b: Void any pending/confirmed income when host has no payout
    -- Covers both: airbnb_email rows (external_ref = confirmation_code)
    --          and synthetic rows (external_ref = 'synthetic-' || confirmation_code)
    IF (NEW.host_payout IS NULL OR NEW.host_payout = 0) THEN
      UPDATE public.transactions
      SET    status     = 'void',
             updated_at = now()
      WHERE  (external_ref = NEW.confirmation_code
              OR external_ref = 'synthetic-' || NEW.confirmation_code)
        AND  status IN ('pending_review', 'confirmed');

      BEGIN
        INSERT INTO public.reconciliation_log (confirmation_code, action, result)
        VALUES (NEW.confirmation_code, 'cancel_void_income', 'voided');
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_fn_reservation_cancel_sync"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_reservation_reconcile"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  -- Only act when status is completed or cancelled-with-payout and checkout has passed
  IF NEW.status IN ('completed', 'cancelled')
     AND NEW.host_payout IS NOT NULL
     AND NEW.host_payout > 0
     AND NEW.checkout_date <= CURRENT_DATE
  THEN
    PERFORM public.ensure_income_transaction(NEW.confirmation_code);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_reservation_reconcile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_kb_document"("p_path" "text", "p_title" "text", "p_content" "text", "p_tags" "text"[] DEFAULT '{}'::"text"[], "p_applies_to" "text"[] DEFAULT '{}'::"text"[], "p_triggers" "text"[] DEFAULT '{}'::"text"[], "p_summary" "text" DEFAULT NULL::"text", "p_doc_type" "text" DEFAULT 'markdown'::"text", "p_github_sha" "text" DEFAULT NULL::"text", "p_github_url" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_id uuid;
  v_hash text := encode(extensions.digest(p_content::bytea, 'sha256'), 'hex');
begin
  insert into public.kb_documents (
    path, title, content, tags, applies_to, triggers,
    summary, doc_type, github_sha, github_url, content_hash
  ) values (
    p_path, p_title, p_content, p_tags, p_applies_to, p_triggers,
    p_summary, p_doc_type, p_github_sha, p_github_url, v_hash
  )
  on conflict (path) do update set
    title=excluded.title, content=excluded.content, tags=excluded.tags,
    applies_to=excluded.applies_to, triggers=excluded.triggers, summary=excluded.summary,
    doc_type=excluded.doc_type, github_sha=excluded.github_sha, github_url=excluded.github_url,
    content_hash=excluded.content_hash, status='active'
  returning id into v_id;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."upsert_kb_document"("p_path" "text", "p_title" "text", "p_content" "text", "p_tags" "text"[], "p_applies_to" "text"[], "p_triggers" "text"[], "p_summary" "text", "p_doc_type" "text", "p_github_sha" "text", "p_github_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."verify_admin_pin"("pin" "text") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
                                  select exists (
                                      select 1 from app_settings
                                          where key = 'admin_pin_hash'
                                                and value #>> '{}' = extensions.crypt(pin, value #>> '{}')
                                                  );
                                                  $$;


ALTER FUNCTION "public"."verify_admin_pin"("pin" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."verify_admin_pin"("p_code" "text", "p_client" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_hash      text;
  v_ok        boolean := false;
  v_ip        text;
  v_recent    int;
  v_users     jsonb;
begin
  -- Identify the caller for throttling. Never store a raw IP: hash it with the
  -- row id space so the table cannot be used to track visitors.
  v_ip := encode(extensions.digest(coalesce(p_client, 'unknown') || '|cascade-guide', 'sha256'), 'hex');

  select count(*) into v_recent
  from admin_auth_attempts
  where ip_hash = v_ip
    and succeeded = false
    and attempted_at > now() - interval '15 minutes';

  if v_recent >= 8 then
    return jsonb_build_object('ok', false, 'throttled', true);
  end if;

  select value #>> '{}' into v_hash from app_settings where key = 'admin_pin_hash';
  if v_hash is null or p_code is null or length(p_code) = 0 then
    insert into admin_auth_attempts (ip_hash, succeeded) values (v_ip, false);
    return jsonb_build_object('ok', false);
  end if;

  -- bcrypt: hashing the candidate with the stored hash as salt reproduces it.
  v_ok := extensions.crypt(lower(trim(p_code)), v_hash) = v_hash;

  insert into admin_auth_attempts (ip_hash, succeeded) values (v_ip, v_ok);

  if not v_ok then
    return jsonb_build_object('ok', false);
  end if;

  select value into v_users from app_settings where key = 'users';
  return jsonb_build_object('ok', true, 'users', coalesce(v_users, '[]'::jsonb));
end;
$$;


ALTER FUNCTION "public"."verify_admin_pin"("p_code" "text", "p_client" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."verify_admin_pin"("p_code" "text", "p_client" "text") IS 'Guest-guide admin gate. Compares a candidate PIN against app_settings.admin_pin_hash (bcrypt) server-side and returns the identity list on success. Throttled to 8 failures per 15 min per hashed client. Replaces the plaintext ADMIN_CODE that was readable in index.html.';



CREATE OR REPLACE FUNCTION "public"."verify_booking"("p_checkin_date" "date", "p_initial" "text" DEFAULT NULL::"text", "p_property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_cal     record;
  v_res     record;
  v_first   text;
  v_last    text;
  v_full    text;
  v_expired boolean;
  v_match   boolean;
  v_il      text;
BEGIN
  -- Find the booking whose check-in date matches exactly. Confirmed only.
  SELECT guest_name, raw_summary, checkin_date, checkout_date, nights, checkin_time, checkout_time
  INTO v_cal
  FROM public.calendar_events
  WHERE property_id  = p_property_id
    AND status       = 'confirmed'
    AND checkin_date = p_checkin_date
  ORDER BY updated_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  -- Expiry: checkout + 1 day grace (mirrors client computeExpiry).
  v_expired := (v_cal.checkout_date + 1) < CURRENT_DATE;

  -- Expired bookings return dates only — never PII.
  IF v_expired THEN
    RETURN jsonb_build_object(
      'found', true, 'expired', true,
      'checkin_date', v_cal.checkin_date,
      'checkout_date', v_cal.checkout_date,
      'nights', v_cal.nights
    );
  END IF;

  -- Resolve name (mirror get_welcome_info: calendar first, else reservation cross-ref).
  IF v_cal.guest_name IS NOT NULL AND trim(v_cal.guest_name) <> '' THEN
    v_full := trim(v_cal.guest_name);
  ELSE
    SELECT guest_name INTO v_res
    FROM public.airbnb_reservations
    WHERE property_id = p_property_id
      AND status NOT IN ('cancelled')
      AND checkin_date BETWEEN v_cal.checkin_date - 2 AND v_cal.checkin_date + 2
    ORDER BY ABS(checkin_date - v_cal.checkin_date) ASC, created_at DESC
    LIMIT 1;
    v_full := CASE
      WHEN v_res.guest_name IS NOT NULL AND trim(v_res.guest_name) <> '' THEN trim(v_res.guest_name)
      ELSE coalesce(nullif(trim(v_cal.raw_summary), ''), 'Guest')
    END;
  END IF;

  v_first := trim(split_part(v_full, ' ', 1));
  v_last  := trim(split_part(v_full, ' ', 2));
  IF lower(v_first) IN ('reserved','airbnb','not','') THEN
    v_first := 'Guest'; v_last := NULL;
  END IF;

  -- Date-only step (no initial yet): dates only, no PII.
  IF p_initial IS NULL OR length(trim(p_initial)) = 0 THEN
    RETURN jsonb_build_object(
      'found', true, 'expired', false,
      'checkin_date', v_cal.checkin_date,
      'checkout_date', v_cal.checkout_date,
      'nights', v_cal.nights,
      'checkin_time', v_cal.checkin_time,
      'checkout_time', v_cal.checkout_time
    );
  END IF;

  -- Initial match (case-insensitive, first OR last initial). Placeholder skips the check.
  v_il := lower(left(trim(p_initial), 1));
  IF lower(v_first) = 'guest' THEN
    v_match := true;
  ELSE
    v_match := (v_il = lower(left(v_first, 1)))
            OR (v_last IS NOT NULL AND v_last <> '' AND v_il = lower(left(v_last, 1)));
  END IF;

  IF NOT v_match THEN
    RETURN jsonb_build_object(
      'found', true, 'expired', false, 'match', false,
      'checkin_date', v_cal.checkin_date,
      'checkout_date', v_cal.checkout_date,
      'nights', v_cal.nights
    );
  END IF;

  RETURN jsonb_build_object(
    'found', true, 'expired', false, 'match', true,
    'first_name', v_first,
    'last_name',  nullif(v_last, ''),
    'full_name',  v_full,
    'checkin_date', v_cal.checkin_date,
    'checkout_date', v_cal.checkout_date,
    'nights', v_cal.nights,
    'checkin_time', v_cal.checkin_time,
    'checkout_time', v_cal.checkout_time
  );
END;
$$;


ALTER FUNCTION "public"."verify_booking"("p_checkin_date" "date", "p_initial" "text", "p_property_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."verify_turnover"("p_checkout_date" "date", "p_property_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_property_id uuid;
  v_session record;
  v_meter record;
  v_issues text[] := '{}';
  v_check_passed boolean := true;
BEGIN
  IF p_property_id IS NULL THEN
    SELECT id INTO v_property_id FROM public.properties LIMIT 1;
  ELSE
    v_property_id := p_property_id;
  END IF;

  -- Check 1: session exists for this checkout_date
  SELECT * INTO v_session
  FROM public.cleaning_sessions
  WHERE property_id = v_property_id
    AND checkout_date = p_checkout_date
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'check_passed', false,
      'session_id', null,
      'cleaner_name', null,
      'total_photo_count', null,
      'is_complete', null,
      'incomplete_reasons', null,
      'issues', ARRAY['no_session_found']
    );
  END IF;

  -- Check 2: meter reading exists
  SELECT * INTO v_meter
  FROM public.meter_readings
  WHERE session_id = v_session.id
  LIMIT 1;

  IF NOT FOUND THEN
    v_issues := array_append(v_issues, 'no_meter_reading');
    v_check_passed := false;
  ELSE
    -- Check 3: sane kwh_per_night (catches stored 0.0000/night bug)
    IF (v_session.nights_stayed IS NOT NULL AND v_session.nights_stayed > 0)
       AND (v_meter.kwh_per_night IS NULL OR v_meter.kwh_per_night = 0) THEN
      v_issues := array_append(v_issues, 'meter_zero_kwh_per_night');
      -- Warning only — not a hard fail (could be a short stay with minimal usage)
    END IF;
  END IF;

  -- Check 4: photo count >= 5
  IF v_session.total_photo_count IS NULL OR v_session.total_photo_count < 5 THEN
    v_issues := array_append(v_issues, 'low_photo_count');
    v_check_passed := false;
  END IF;

  -- Check 5: session completeness
  IF v_session.is_complete IS NOT TRUE THEN
    v_issues := array_append(v_issues, 'session_incomplete');
    IF v_session.incomplete_reasons IS NOT NULL AND
       array_length(v_session.incomplete_reasons, 1) > 0 THEN
      v_issues := v_issues || v_session.incomplete_reasons;
    END IF;
    v_check_passed := false;
  END IF;

  RETURN jsonb_build_object(
    'check_passed', v_check_passed,
    'session_id', v_session.id,
    'cleaner_name', v_session.cleaner_name,
    'total_photo_count', COALESCE(v_session.total_photo_count, 0),
    'is_complete', v_session.is_complete,
    'incomplete_reasons', v_session.incomplete_reasons,
    'issues', v_issues
  );
END;
$$;


ALTER FUNCTION "public"."verify_turnover"("p_checkout_date" "date", "p_property_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."admin_auth_attempts" (
    "id" bigint NOT NULL,
    "ip_hash" "text" NOT NULL,
    "succeeded" boolean DEFAULT false NOT NULL,
    "attempted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."admin_auth_attempts" OWNER TO "postgres";


COMMENT ON TABLE "public"."admin_auth_attempts" IS 'Throttles the guest-guide admin PIN check. Written only by the verify-admin Edge Function (service role). ip_hash is a salted hash, never a raw IP.';



ALTER TABLE "public"."admin_auth_attempts" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."admin_auth_attempts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."airbnb_transactions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "row_type" "text" NOT NULL,
    "txn_date" "date" NOT NULL,
    "arriving_by_date" "date",
    "confirmation_code" "text",
    "booking_date" "date",
    "start_date" "date",
    "end_date" "date",
    "nights" integer,
    "guest_name" "text",
    "listing" "text",
    "details" "text",
    "reference_code" "text",
    "currency" "text" DEFAULT 'PHP'::"text",
    "amount" numeric,
    "paid_out" numeric,
    "service_fee" numeric,
    "fast_pay_fee" numeric,
    "cleaning_fee" numeric,
    "gross_earnings" numeric,
    "airbnb_remitted_tax" numeric,
    "earnings_year" integer,
    "payout_account" "text",
    "source_file" "text",
    "row_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "airbnb_transactions_row_type_check" CHECK (("row_type" = ANY (ARRAY['payout'::"text", 'reservation'::"text", 'adjustment'::"text", 'cohost_payout'::"text"])))
);


ALTER TABLE "public"."airbnb_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cleaner_rate_schedule" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "effective_from" "date" NOT NULL,
    "regular_rate" numeric NOT NULL,
    "general_rate" numeric,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."cleaner_rate_schedule" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."airbnb_cleans" WITH ("security_invoker"='on') AS
 SELECT "confirmation_code",
    "guest_name",
    "start_date",
    "end_date" AS "clean_date",
    "nights",
    ( SELECT "s"."regular_rate"
           FROM "public"."cleaner_rate_schedule" "s"
          WHERE (("s"."property_id" = "r"."property_id") AND ("s"."effective_from" <= "r"."end_date"))
          ORDER BY "s"."effective_from" DESC
         LIMIT 1) AS "applicable_regular_rate",
    ( SELECT "s"."general_rate"
           FROM "public"."cleaner_rate_schedule" "s"
          WHERE (("s"."property_id" = "r"."property_id") AND ("s"."effective_from" <= "r"."end_date"))
          ORDER BY "s"."effective_from" DESC
         LIMIT 1) AS "applicable_general_rate"
   FROM "public"."airbnb_transactions" "r"
  WHERE (("row_type" = 'reservation'::"text") AND ("end_date" IS NOT NULL));


ALTER VIEW "public"."airbnb_cleans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."airbnb_email_events" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "gmail_message_id" "text" NOT NULL,
    "email_type" "text" NOT NULL,
    "email_date" timestamp with time zone NOT NULL,
    "subject" "text",
    "raw_payload" "jsonb",
    "processed_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "airbnb_email_events_email_type_check" CHECK (("email_type" = ANY (ARRAY['payout'::"text", 'booking'::"text", 'cancellation'::"text"])))
);


ALTER TABLE "public"."airbnb_email_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."airbnb_email_events" IS 'Idempotency log for all Airbnb emails processed by AirbnbEmailSync.gs. gmail_message_id is the dedup key — re-runs are always safe.';



CREATE OR REPLACE VIEW "public"."airbnb_guest_summary" WITH ("security_invoker"='on') AS
 SELECT "guest_name",
    "count"(*) AS "stays",
    "sum"("nights") AS "total_nights",
    "round"("sum"("amount"), 2) AS "total_host_net",
    "min"("start_date") AS "first_stay",
    "max"("end_date") AS "last_checkout"
   FROM "public"."airbnb_transactions"
  WHERE (("row_type" = 'reservation'::"text") AND ("guest_name" IS NOT NULL))
  GROUP BY "guest_name"
  ORDER BY ("round"("sum"("amount"), 2)) DESC;


ALTER VIEW "public"."airbnb_guest_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."airbnb_monthly_revenue" WITH ("security_invoker"='on') AS
 SELECT "to_char"("date_trunc"('month'::"text", ("end_date")::timestamp with time zone), 'YYYY-MM'::"text") AS "month",
    "count"(*) AS "stays",
    "sum"("nights") AS "room_nights",
    "round"("sum"("gross_earnings"), 2) AS "gross_earnings",
    "round"("sum"("service_fee"), 2) AS "airbnb_service_fees",
    "round"("sum"("amount"), 2) AS "host_net",
    "round"("avg"(("amount" / (NULLIF("nights", 0))::numeric)), 2) AS "avg_net_per_night"
   FROM "public"."airbnb_transactions"
  WHERE (("row_type" = 'reservation'::"text") AND ("end_date" IS NOT NULL))
  GROUP BY ("to_char"("date_trunc"('month'::"text", ("end_date")::timestamp with time zone), 'YYYY-MM'::"text"))
  ORDER BY ("to_char"("date_trunc"('month'::"text", ("end_date")::timestamp with time zone), 'YYYY-MM'::"text"));


ALTER VIEW "public"."airbnb_monthly_revenue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."airbnb_reservations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "confirmation_code" "text" NOT NULL,
    "source" "text" DEFAULT 'airbnb'::"text" NOT NULL,
    "status" "text" DEFAULT 'confirmed'::"text" NOT NULL,
    "guest_id" "uuid",
    "guest_name" "text",
    "guest_count" integer,
    "checkin_date" "date",
    "checkout_date" "date",
    "checkin_time" "text",
    "checkout_time" "text",
    "nights" integer GENERATED ALWAYS AS (("checkout_date" - "checkin_date")) STORED,
    "guest_paid" numeric(12,2),
    "host_service_fee" numeric(12,2),
    "host_payout" numeric(12,2),
    "payout_amount" numeric(12,2),
    "payout_date" "date",
    "payout_email_message_id" "text",
    "cancelled_at" timestamp with time zone,
    "refund_type" "text",
    "booking_email_message_id" "text",
    "cancel_email_message_id" "text",
    CONSTRAINT "airbnb_reservations_source_check" CHECK (("source" = ANY (ARRAY['airbnb'::"text", 'direct'::"text", 'other'::"text"]))),
    CONSTRAINT "airbnb_reservations_status_check" CHECK (("status" = ANY (ARRAY['confirmed'::"text", 'cancelled'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."airbnb_reservations" OWNER TO "postgres";


COMMENT ON TABLE "public"."airbnb_reservations" IS 'One row per Airbnb reservation. Created from booking confirmation email, enriched by payout email, marked cancelled by cancellation email. confirmation_code is the universal join key across all email types.';



CREATE TABLE IF NOT EXISTS "public"."app_secrets" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL
);


ALTER TABLE "public"."app_secrets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_settings" (
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."app_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."booking_inquiries" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "guest_name" "text" NOT NULL,
    "guest_email" "text",
    "guest_phone" "text",
    "checkin_date" "date" NOT NULL,
    "checkout_date" "date" NOT NULL,
    "nights" integer GENERATED ALWAYS AS (("checkout_date" - "checkin_date")) STORED,
    "pax" integer,
    "total_amount" numeric(10,2),
    "deposit_amount" numeric(10,2),
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "source" "text" DEFAULT 'direct'::"text",
    "notes" "text",
    "submitted_at" timestamp with time zone DEFAULT "now"(),
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "guest_id" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "receipt_image_path" "text"
);


ALTER TABLE "public"."booking_inquiries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."calendar_events" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" NOT NULL,
    "uid" "text" NOT NULL,
    "source" "text" DEFAULT 'airbnb'::"text" NOT NULL,
    "checkin_date" "date" NOT NULL,
    "checkout_date" "date" NOT NULL,
    "nights" integer GENERATED ALWAYS AS (("checkout_date" - "checkin_date")) STORED,
    "guest_name" "text",
    "guest_phone" "text",
    "status" "text" DEFAULT 'confirmed'::"text" NOT NULL,
    "raw_summary" "text",
    "raw_description" "text",
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "checkin_time" time without time zone,
    "checkout_time" time without time zone,
    "linked_reservation_id" "uuid",
    "recon_status" "text" DEFAULT 'pending'::"text",
    "recon_alerted_at" timestamp with time zone,
    CONSTRAINT "calendar_events_recon_status_check" CHECK (("recon_status" = ANY (ARRAY['pending'::"text", 'matched'::"text", 'fuzzy_match'::"text", 'unmatched'::"text", 'admin_block'::"text", 'manual_entry'::"text", 'skipped'::"text"]))),
    CONSTRAINT "calendar_events_source_check" CHECK (("source" = ANY (ARRAY['airbnb'::"text", 'direct'::"text", 'manual'::"text"]))),
    CONSTRAINT "calendar_events_status_check" CHECK (("status" = ANY (ARRAY['confirmed'::"text", 'blocked'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."calendar_events" OWNER TO "postgres";


COMMENT ON COLUMN "public"."calendar_events"."checkin_time" IS 'Optional check-in time for turnover-window rain forecast';



COMMENT ON COLUMN "public"."calendar_events"."checkout_time" IS 'Optional check-out time for turnover-window rain forecast';



COMMENT ON COLUMN "public"."calendar_events"."linked_reservation_id" IS 'FK to airbnb_reservations once reconciled. Null = not yet matched.';



COMMENT ON COLUMN "public"."calendar_events"."recon_status" IS 'pending=not yet checked; matched=exact; fuzzy_match=alerted, awaiting confirm; unmatched=alerted, no reservation; admin_block=manually blocked; manual_entry=manually created; skipped=dismissed.';



COMMENT ON COLUMN "public"."calendar_events"."recon_alerted_at" IS 'Timestamp of last OPS Telegram alert for this block. Null = not yet alerted.';



CREATE TABLE IF NOT EXISTS "public"."calendar_sync_log" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" NOT NULL,
    "source" "text" DEFAULT 'airbnb'::"text" NOT NULL,
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "event_count" integer,
    "status" "text" DEFAULT 'ok'::"text",
    "error_msg" "text"
);


ALTER TABLE "public"."calendar_sync_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cascade_manual_sections" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "section_key" "text" NOT NULL,
    "title" "text" NOT NULL,
    "min_role" "text" DEFAULT 'staff'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "content_blocks" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "cascade_manual_sections_min_role_check" CHECK (("min_role" = ANY (ARRAY['staff'::"text", 'owner'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."cascade_manual_sections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cleaning_diagnostics" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "property_id" "uuid" NOT NULL,
    "submission_id" "text",
    "user_agent" "text",
    "device_model" "text",
    "os_version" "text",
    "upload_retry_count" integer DEFAULT 0 NOT NULL,
    "photos_failed" integer DEFAULT 0 NOT NULL,
    "session_duration_s" integer,
    "app_version" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."cleaning_diagnostics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cleaning_sessions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "submission_id" "text" NOT NULL,
    "cleaner_name" "text" NOT NULL,
    "cleaned_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_guest_name" "text",
    "nights_stayed" integer,
    "checkin_date" "date",
    "checkout_date" "date",
    "completion_pct" numeric(5,2),
    "checklist_details" "jsonb",
    "notes" "text",
    "session_folder_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "property_id" "uuid",
    "cleaning_type" "text",
    "fee_amount" numeric,
    "fee_paid_at" timestamp with time zone,
    "fee_txn_id" "uuid",
    "fee_acked_at" timestamp with time zone,
    "employee_id" "uuid",
    "preclean_photo_count" integer,
    "afterclean_photo_count" integer,
    "meter_photo_count" integer,
    "other_photo_count" integer,
    "total_photo_count" integer,
    "issue_count" integer,
    "is_complete" boolean,
    "incomplete_reasons" "text"[]
);


ALTER TABLE "public"."cleaning_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dining_spots" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "cuisine" "text",
    "price_range" "text",
    "lat" numeric(10,7) NOT NULL,
    "lng" numeric(10,7) NOT NULL,
    "address" "text",
    "hours" "text",
    "note" "text",
    "distance_km" numeric(5,2),
    "is_active" boolean DEFAULT true,
    "sort_order" integer DEFAULT 0,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "description" "text",
    "distance_text" "text",
    "google_maps_url" "text",
    "phone" "text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "must_try" "text",
    "is_recommended" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."dining_spots" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employees" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "nickname" "text",
    "role" "text" DEFAULT 'cleaner'::"text" NOT NULL,
    "phone" "text",
    "address" "text",
    "photo_url" "text",
    "tin" "text",
    "sss_number" "text",
    "philhealth_number" "text",
    "pagibig_number" "text",
    "hire_date" "date",
    "end_date" "date",
    "end_reason" "text",
    "employment_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "telegram_user_id" "text",
    "rate_override" numeric,
    "notes" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "employees_role_check" CHECK (("role" = ANY (ARRAY['cleaner'::"text", 'caretaker'::"text", 'maintenance'::"text"]))),
    CONSTRAINT "employees_status_check" CHECK (("employment_status" = ANY (ARRAY['active'::"text", 'resigned'::"text", 'terminated'::"text", 'on_leave'::"text"])))
);


ALTER TABLE "public"."employees" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expense_categories" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "slug" "text" NOT NULL,
    "label" "text" NOT NULL,
    "keywords" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "sort_order" integer DEFAULT 100 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."expense_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."guests" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "phone" "text",
    "email" "text",
    "source" "text" DEFAULT 'direct'::"text" NOT NULL,
    "notes" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "tier" "text",
    "total_stays" integer DEFAULT 0,
    "total_nights_stayed" integer DEFAULT 0,
    "first_stay_date" "date",
    "last_stay_date" "date",
    CONSTRAINT "guests_source_check" CHECK (("source" = ANY (ARRAY['direct'::"text", 'airbnb'::"text", 'manual'::"text"])))
);


ALTER TABLE "public"."guests" OWNER TO "postgres";


COMMENT ON TABLE "public"."guests" IS 'CRM foundation — one row per unique guest (deduped by phone). Direct bookings create/link a guest row via submit-booking Edge Function.';



CREATE TABLE IF NOT EXISTS "public"."inventory_audit_log" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid",
    "action" "text" NOT NULL,
    "before" "jsonb",
    "after" "jsonb",
    "actor" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."inventory_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_items" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "unit" "text" DEFAULT 'pc'::"text" NOT NULL,
    "qty_on_hand" numeric(10,2) DEFAULT 0 NOT NULL,
    "reorder_below" numeric(10,2),
    "is_consumable" boolean DEFAULT false NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "photo_path" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "status" "text" DEFAULT 'Good'::"text",
    "replace_freq" "text",
    "unit_cost" numeric(10,2),
    "consumption_per_booking" numeric(10,2),
    "legacy_id" "text",
    "resolved_at" timestamp with time zone,
    "resolution_note" "text",
    "purchase_unit" "text",
    "units_per_purchase" numeric(10,4) DEFAULT 1
);


ALTER TABLE "public"."inventory_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_purchases" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "item_id" "uuid",
    "purchased_at" "date" DEFAULT CURRENT_DATE NOT NULL,
    "qty" numeric(10,2) NOT NULL,
    "unit_cost" numeric(10,2),
    "total_cost" numeric(10,2) GENERATED ALWAYS AS (("qty" * "unit_cost")) STORED,
    "supplier" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "batch_id" "uuid",
    "item_legacy_id" "text",
    "receipt_path" "text",
    "purchase_unit" "text",
    "units_per_purchase" integer DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."inventory_purchases" OWNER TO "postgres";


COMMENT ON COLUMN "public"."inventory_purchases"."purchase_unit" IS 'Purchase unit label at time of purchase (pack, bottle, sachet, etc.)';



COMMENT ON COLUMN "public"."inventory_purchases"."units_per_purchase" IS 'How many base units per purchase unit at time of purchase. qty × units_per_purchase = base units added to stock.';



CREATE TABLE IF NOT EXISTS "public"."inventory_usage" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "item_id" "uuid",
    "used_qty" numeric(10,2) NOT NULL,
    "session_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "logged_by" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."inventory_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kb_documents" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "path" "text" NOT NULL,
    "title" "text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "applies_to" "text"[] DEFAULT '{}'::"text"[],
    "triggers" "text"[] DEFAULT '{}'::"text"[],
    "doc_type" "text" DEFAULT 'markdown'::"text",
    "content" "text" NOT NULL,
    "summary" "text",
    "content_hash" "text",
    "fts" "tsvector",
    "embedding" "extensions"."vector"(1536),
    "github_sha" "text",
    "github_url" "text",
    "status" "text" DEFAULT 'active'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."kb_documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."meter_readings" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "session_id" "uuid",
    "electric_prev" numeric(10,2),
    "electric_curr" numeric(10,2),
    "electric_delta" numeric(10,2),
    "water_prev" numeric(10,4),
    "water_curr" numeric(10,4),
    "water_delta" numeric(10,4),
    "kwh_per_night" numeric(10,4),
    "m3_per_night" numeric(10,4),
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "property_id" "uuid",
    "meter_flag" "text",
    "meter_override_note" "text"
);


ALTER TABLE "public"."meter_readings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ops_notices" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" NOT NULL,
    "notice_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "effective_date" "date" NOT NULL,
    "effective_time" time without time zone,
    "duration_hours" numeric(4,1),
    "feeder" "text",
    "posted_by_chat_id" bigint,
    "posted_by_name" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "ops_notices_notice_type_check" CHECK (("notice_type" = ANY (ARRAY['brownout'::"text", 'holiday'::"text", 'event'::"text", 'reminder'::"text"])))
);


ALTER TABLE "public"."ops_notices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pois" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "lat" numeric(10,7) NOT NULL,
    "lng" numeric(10,7) NOT NULL,
    "address" "text",
    "hours" "text",
    "note" "text",
    "distance_km" numeric(5,2),
    "is_active" boolean DEFAULT true,
    "sort_order" integer DEFAULT 0,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "description" "text",
    "distance_text" "text",
    "google_maps_url" "text",
    "phone" "text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."pois" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."price_history_by_item" WITH ("security_invoker"='true') AS
 SELECT "item_id",
    "item_name",
    "supplier",
    "unit_cost",
    "purchased_at",
    "recency_rank"
   FROM "public"."price_history_by_item";


ALTER VIEW "public"."price_history_by_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."properties" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "address" "text",
    "city" "text",
    "country" "text" DEFAULT 'PH'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."properties" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reconciliation_log" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "called_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "confirmation_code" "text",
    "action" "text",
    "result" "text",
    "error_msg" "text"
);


ALTER TABLE "public"."reconciliation_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."returning_guest_alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "property_id" "uuid",
    "guest_name" "text" NOT NULL,
    "current_checkin" "date",
    "current_checkout" "date",
    "current_nights" integer,
    "previous_stays" integer DEFAULT 0,
    "total_nights" integer DEFAULT 0,
    "last_stay_checkin" "date",
    "last_stay_checkout" "date",
    "telegram_sent" boolean DEFAULT false,
    "telegram_sent_at" timestamp with time zone,
    "source" "text" DEFAULT 'welcome_guide'::"text"
);


ALTER TABLE "public"."returning_guest_alerts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."telegram_chat_history" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "chat_id" "text" NOT NULL,
    "role" "text" NOT NULL,
    "parts" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "telegram_chat_history_role_check" CHECK (("role" = ANY (ARRAY['user'::"text", 'model'::"text"])))
);


ALTER TABLE "public"."telegram_chat_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."telegram_pending" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "chat_id" bigint NOT NULL,
    "kind" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:10:00'::interval) NOT NULL,
    CONSTRAINT "telegram_pending_kind_check" CHECK (("kind" = ANY (ARRAY['duplicate'::"text", 'large_amount'::"text", 'photo_dup'::"text", 'inventory_sync'::"text"])))
);


ALTER TABLE "public"."telegram_pending" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."telegram_processed_updates" (
    "update_id" bigint NOT NULL,
    "processed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."telegram_processed_updates" OWNER TO "postgres";


COMMENT ON TABLE "public"."telegram_processed_updates" IS 'Webhook idempotency: telegram-expense records each Telegram update_id (insert-or-ignore) so a re-delivered update is processed at most once. Service-role only (RLS on, no policies). Rows older than ~2d purged opportunistically by the function.';



CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::"uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "txn_type" "text" NOT NULL,
    "category" "text" NOT NULL,
    "status" "text" DEFAULT 'confirmed'::"text" NOT NULL,
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    "transaction_date" "date" DEFAULT (("now"() AT TIME ZONE 'Asia/Manila'::"text"))::"date" NOT NULL,
    "gross_amount" numeric(12,2) NOT NULL,
    "currency" "text" DEFAULT 'PHP'::"text" NOT NULL,
    "or_number" "text",
    "payee_name" "text",
    "payee_tin" "text",
    "tax_base" numeric(12,2),
    "tax_amount" numeric(12,2),
    "tax_treatment" "text",
    "receipt_image_path" "text",
    "ocr_confidence" numeric(5,2),
    "ocr_raw" "jsonb",
    "booking_id" "uuid",
    "logged_by" "text",
    "notes" "text",
    "external_ref" "text",
    "income_stage" "text",
    "refund_rail" "text",
    "refund_ref" "text",
    CONSTRAINT "transactions_gross_amount_check" CHECK (("gross_amount" >= (0)::numeric)),
    CONSTRAINT "transactions_income_stage_check" CHECK (("income_stage" = ANY (ARRAY['estimated'::"text", 'confirmed'::"text", 'reconciliation'::"text"]))),
    CONSTRAINT "transactions_refund_rail_check" CHECK ((("refund_rail" IS NULL) OR ("refund_rail" = ANY (ARRAY['offplatform'::"text", 'resolution_center'::"text"])))),
    CONSTRAINT "transactions_source_check" CHECK (("source" = ANY (ARRAY['telegram'::"text", 'ocr'::"text", 'booking'::"text", 'manual'::"text", 'import'::"text", 'airbnb'::"text", 'airbnb_email'::"text", 'airbnb_payout_email'::"text", 'direct_booking'::"text", 'cleaner_fee'::"text", 'refund'::"text"]))),
    CONSTRAINT "transactions_status_check" CHECK (("status" = ANY (ARRAY['pending_review'::"text", 'confirmed'::"text", 'void'::"text"]))),
    CONSTRAINT "transactions_tax_treatment_check" CHECK ((("tax_treatment" IS NULL) OR ("tax_treatment" = ANY (ARRAY['vat_exempt'::"text", 'zero_rated'::"text", 'vatable'::"text", 'non_vat'::"text"])))),
    CONSTRAINT "transactions_txn_type_check" CHECK (("txn_type" = ANY (ARRAY['income'::"text", 'expense'::"text"])))
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";


COMMENT ON TABLE "public"."transactions" IS 'Unified financial ledger (income + expense). Sources: telegram expense logging, OCR receipts, booking income, manual. BIR fields nullable until registration.';



CREATE TABLE IF NOT EXISTS "public"."turnover_verification" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "property_id" "uuid" NOT NULL,
    "checkout_date" "date" NOT NULL,
    "session_id" "uuid",
    "check_passed" boolean DEFAULT false NOT NULL,
    "issues" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "alert_24h_sent_at" timestamp with time zone,
    "alert_36h_sent_at" timestamp with time zone,
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."turnover_verification" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_canonical_ledger" WITH ("security_invoker"='true') AS
 SELECT "t"."property_id",
    "t"."transaction_date",
    'income'::"text" AS "txn_type",
    'airbnb_payout'::"text" AS "category",
    "t"."gross_amount",
    "t"."status",
    "t"."payee_name",
    "t"."external_ref" AS "reference",
    "t"."source",
    NULL::integer AS "nights",
    NULL::"date" AS "checkin_date",
    NULL::"date" AS "checkout_date"
   FROM "public"."transactions" "t"
  WHERE (("t"."txn_type" = 'income'::"text") AND ("t"."source" = 'airbnb_payout_email'::"text") AND ("t"."income_stage" = 'confirmed'::"text") AND ("t"."status" = 'confirmed'::"text"))
UNION ALL
 SELECT "t"."property_id",
    "t"."transaction_date",
    "t"."txn_type",
    "t"."category",
    "t"."gross_amount",
    "t"."status",
    "t"."payee_name",
    "t"."or_number" AS "reference",
    "t"."source",
    NULL::integer AS "nights",
    NULL::"date" AS "checkin_date",
    NULL::"date" AS "checkout_date"
   FROM "public"."transactions" "t"
  WHERE (("t"."txn_type" = 'expense'::"text") AND ("t"."status" = 'confirmed'::"text"));


ALTER VIEW "public"."v_canonical_ledger" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_direct_bookings" WITH ("security_invoker"='false') AS
 SELECT "id",
    "upper"("left"(("id")::"text", 8)) AS "ref",
    "guest_name",
    "checkin_date",
    "checkout_date",
    ("checkout_date" - "checkin_date") AS "nights",
    "pax",
    "total_amount",
    "deposit_amount",
    "status",
    ("receipt_image_path" IS NOT NULL) AS "has_receipt",
    "updated_at"
   FROM "public"."booking_inquiries"
  WHERE ("source" = 'direct'::"text");


ALTER VIEW "public"."v_direct_bookings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_direct_state_desync" AS
 SELECT "bi"."id",
    "bi"."guest_name",
    "bi"."checkin_date",
    "bi"."status" AS "inq_status",
    "ce"."status" AS "cal_status",
    "t"."status" AS "txn_status"
   FROM (("public"."booking_inquiries" "bi"
     LEFT JOIN "public"."calendar_events" "ce" ON (("ce"."uid" = ('direct:'::"text" || "bi"."id"))))
     LEFT JOIN "public"."transactions" "t" ON (("t"."external_ref" = ("bi"."id")::"text")))
  WHERE (("bi"."source" = 'direct'::"text") AND ((("bi"."status" = 'pending'::"text") AND (("ce"."status" <> 'blocked'::"text") OR ("t"."status" <> 'pending_review'::"text"))) OR (("bi"."status" = 'confirmed'::"text") AND (("ce"."status" <> 'confirmed'::"text") OR ("t"."status" <> 'confirmed'::"text"))) OR (("bi"."status" = 'cancelled'::"text") AND (("ce"."status" <> 'cancelled'::"text") OR ("t"."status" <> 'void'::"text")))));


ALTER VIEW "public"."v_direct_state_desync" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_finance_orphans" WITH ("security_invoker"='true') AS
 SELECT "confirmation_code",
    "guest_name",
    "checkout_date",
    "nights",
    "host_payout",
    "status" AS "booking_status"
   FROM "public"."airbnb_reservations" "r"
  WHERE (("status" = 'completed'::"text") AND ("host_payout" IS NOT NULL) AND ("host_payout" > (0)::numeric) AND ("checkout_date" <= CURRENT_DATE) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."airbnb_email_events" "e",
            LATERAL "jsonb_array_elements"(("e"."raw_payload" -> 'detail_lines'::"text")) "dl"("value")
          WHERE (("e"."email_type" = 'payout'::"text") AND (("dl"."value" ->> 'line_type'::"text") = 'Home'::"text") AND (("dl"."value" ->> 'confirmation_code'::"text") = "r"."confirmation_code"))))) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."transactions" "t"
          WHERE (("t"."source" = 'airbnb_payout_email'::"text") AND ("t"."income_stage" = 'confirmed'::"text") AND ("t"."status" = 'confirmed'::"text") AND ("t"."external_ref" = ('synthetic-'::"text" || "r"."confirmation_code")))))))
  ORDER BY "checkout_date" DESC;


ALTER VIEW "public"."v_finance_orphans" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_guest_refunds" WITH ("security_invoker"='true') AS
 SELECT "r"."id" AS "refund_id",
    "r"."transaction_date" AS "refund_date",
    "r"."gross_amount" AS "refund_amount",
    "r"."payee_name" AS "recipient",
    "r"."refund_rail",
    "r"."refund_ref" AS "payment_reference",
    "r"."notes",
    "r"."external_ref" AS "booking_ref",
    "r"."logged_by",
    "i"."gross_amount" AS "original_payout",
    "i"."transaction_date" AS "payout_date",
    "i"."source" AS "income_source",
    (COALESCE("i"."gross_amount", (0)::numeric) - "r"."gross_amount") AS "net_after_refund",
        CASE
            WHEN ("r"."refund_rail" = 'resolution_center'::"text") THEN true
            ELSE false
        END AS "airbnb_netted",
    "ar"."guest_name"
   FROM (("public"."transactions" "r"
     LEFT JOIN "public"."transactions" "i" ON ((("i"."external_ref" = "r"."external_ref") AND ("i"."txn_type" = 'income'::"text") AND ("i"."source" = 'airbnb_payout_email'::"text") AND ("i"."status" = 'confirmed'::"text"))))
     LEFT JOIN "public"."airbnb_reservations" "ar" ON (("ar"."confirmation_code" = "r"."external_ref")))
  WHERE (("r"."txn_type" = 'expense'::"text") AND ("r"."source" = 'refund'::"text") AND ("r"."status" = 'confirmed'::"text"));


ALTER VIEW "public"."v_guest_refunds" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_guest_refunds" IS 'Guest refund records joined with original payout and reservation data. Uses SECURITY INVOKER so RLS on base tables is enforced.';



CREATE OR REPLACE VIEW "public"."v_income_canonical" WITH ("security_invoker"='on') AS
 SELECT "id",
    "property_id",
    "created_at",
    "updated_at",
    "txn_type",
    "category",
    "status",
    "source",
    "transaction_date",
    "gross_amount",
    "currency",
    "or_number",
    "payee_name",
    "payee_tin",
    "tax_base",
    "tax_amount",
    "tax_treatment",
    "receipt_image_path",
    "ocr_confidence",
    "ocr_raw",
    "booking_id",
    "logged_by",
    "notes",
    "external_ref",
    "income_stage"
   FROM "public"."transactions"
  WHERE (("txn_type" = 'income'::"text") AND ((("source" = 'airbnb'::"text") AND ("status" = 'confirmed'::"text")) OR (("source" = 'airbnb_email'::"text") AND ("status" = 'pending_review'::"text")) OR ("source" <> ALL (ARRAY['airbnb'::"text", 'airbnb_email'::"text", 'airbnb_payout_email'::"text"]))));


ALTER VIEW "public"."v_income_canonical" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_income_canonical" IS 'CANONICAL income source for all Finance aggregation. Never SUM transactions.income across all sources — airbnb/airbnb_email/airbnb_payout_email all write rows for the same booking (triple-count risk). This view surfaces only the CSV-authoritative confirmed rows + unresolved pending. Updated 2026-06-05 during dashboard v6 dedup.';



CREATE OR REPLACE VIEW "public"."v_status_desync" WITH ("security_invoker"='true') AS
 SELECT DISTINCT "ce"."id" AS "calendar_event_id",
    "ce"."uid",
    "ce"."property_id",
    "ar"."id" AS "reservation_id",
    "ar"."confirmation_code",
    "ar"."guest_name",
    "ce"."status" AS "cal_status",
    "ar"."status" AS "rsv_status",
    "ce"."checkin_date" AS "cal_checkin",
    "ar"."checkin_date" AS "rsv_checkin",
    "ce"."checkout_date" AS "cal_checkout",
    "ar"."checkout_date" AS "rsv_checkout",
    "ce"."recon_status",
        CASE
            WHEN (("ce"."status" = 'cancelled'::"text") AND ("ar"."status" <> ALL (ARRAY['cancelled'::"text", 'rejected'::"text"]))) THEN 'cal_cancelled_rsv_active'::"text"
            WHEN (("ar"."status" = 'cancelled'::"text") AND ("ce"."status" <> ALL (ARRAY['cancelled'::"text", 'rejected'::"text"]))) THEN 'rsv_cancelled_cal_active'::"text"
            WHEN ("abs"(("ce"."checkin_date" - "ar"."checkin_date")) > 2) THEN 'date_mismatch_checkin'::"text"
            WHEN ("abs"(("ce"."checkout_date" - "ar"."checkout_date")) > 2) THEN 'date_mismatch_checkout'::"text"
            ELSE 'other'::"text"
        END AS "desync_reason"
   FROM ("public"."calendar_events" "ce"
     JOIN "public"."airbnb_reservations" "ar" ON ((("ce"."property_id" = "ar"."property_id") AND (("ce"."linked_reservation_id" = "ar"."id") OR ("upper"("ce"."uid") ~~ (('%'::"text" || "upper"("ar"."confirmation_code")) || '%'::"text"))))))
  WHERE ((("ce"."status" = 'cancelled'::"text") AND ("ar"."status" <> ALL (ARRAY['cancelled'::"text", 'rejected'::"text"]))) OR (("ar"."status" = 'cancelled'::"text") AND ("ce"."status" <> ALL (ARRAY['cancelled'::"text", 'rejected'::"text"]))) OR ("abs"(("ce"."checkin_date" - "ar"."checkin_date")) > 2) OR ("abs"(("ce"."checkout_date" - "ar"."checkout_date")) > 2));


ALTER VIEW "public"."v_status_desync" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_status_desync_wide" AS
 SELECT "ce"."guest_name",
    "ce"."checkin_date" AS "cal_in",
    "r"."checkin_date" AS "rsv_in",
    "ce"."checkout_date" AS "cal_out",
    "r"."checkout_date" AS "rsv_out",
    "ce"."nights" AS "cal_n",
    "r"."nights" AS "rsv_n",
    "r"."confirmation_code",
    ("ce"."linked_reservation_id" IS NOT NULL) AS "linked"
   FROM ("public"."calendar_events" "ce"
     JOIN "public"."airbnb_reservations" "r" ON (("lower"("r"."guest_name") = "lower"("ce"."guest_name"))))
  WHERE (("ce"."source" = 'airbnb'::"text") AND (("ce"."checkin_date" <> "r"."checkin_date") OR ("ce"."checkout_date" <> "r"."checkout_date") OR (COALESCE("ce"."nights", 0) <> COALESCE("r"."nights", 0))));


ALTER VIEW "public"."v_status_desync_wide" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admin_auth_attempts"
    ADD CONSTRAINT "admin_auth_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."airbnb_email_events"
    ADD CONSTRAINT "airbnb_email_events_gmail_message_id_key" UNIQUE ("gmail_message_id");



ALTER TABLE ONLY "public"."airbnb_email_events"
    ADD CONSTRAINT "airbnb_email_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."airbnb_reservations"
    ADD CONSTRAINT "airbnb_reservations_confirmation_code_key" UNIQUE ("confirmation_code");



ALTER TABLE ONLY "public"."airbnb_reservations"
    ADD CONSTRAINT "airbnb_reservations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."airbnb_transactions"
    ADD CONSTRAINT "airbnb_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."airbnb_transactions"
    ADD CONSTRAINT "airbnb_transactions_row_hash_key" UNIQUE ("row_hash");



ALTER TABLE ONLY "public"."app_secrets"
    ADD CONSTRAINT "app_secrets_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."booking_inquiries"
    ADD CONSTRAINT "booking_inquiries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."calendar_events"
    ADD CONSTRAINT "calendar_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."calendar_events"
    ADD CONSTRAINT "calendar_events_uid_property_unique" UNIQUE ("uid", "property_id");



ALTER TABLE ONLY "public"."calendar_sync_log"
    ADD CONSTRAINT "calendar_sync_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cascade_manual_sections"
    ADD CONSTRAINT "cascade_manual_sections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cascade_manual_sections"
    ADD CONSTRAINT "cascade_manual_sections_property_id_section_key_key" UNIQUE ("property_id", "section_key");



ALTER TABLE ONLY "public"."cleaner_rate_schedule"
    ADD CONSTRAINT "cleaner_rate_schedule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cleaning_diagnostics"
    ADD CONSTRAINT "cleaning_diagnostics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cleaning_sessions"
    ADD CONSTRAINT "cleaning_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cleaning_sessions"
    ADD CONSTRAINT "cleaning_sessions_submission_id_key" UNIQUE ("submission_id");



ALTER TABLE ONLY "public"."dining_spots"
    ADD CONSTRAINT "dining_spots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expense_categories"
    ADD CONSTRAINT "expense_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expense_categories"
    ADD CONSTRAINT "expense_categories_property_id_slug_key" UNIQUE ("property_id", "slug");



ALTER TABLE ONLY "public"."guests"
    ADD CONSTRAINT "guests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_audit_log"
    ADD CONSTRAINT "inventory_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_items"
    ADD CONSTRAINT "inventory_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_purchases"
    ADD CONSTRAINT "inventory_purchases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_usage"
    ADD CONSTRAINT "inventory_usage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kb_documents"
    ADD CONSTRAINT "kb_documents_path_key" UNIQUE ("path");



ALTER TABLE ONLY "public"."kb_documents"
    ADD CONSTRAINT "kb_documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."meter_readings"
    ADD CONSTRAINT "meter_readings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ops_notices"
    ADD CONSTRAINT "ops_notices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pois"
    ADD CONSTRAINT "pois_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."properties"
    ADD CONSTRAINT "properties_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reconciliation_log"
    ADD CONSTRAINT "reconciliation_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."returning_guest_alerts"
    ADD CONSTRAINT "returning_guest_alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."telegram_chat_history"
    ADD CONSTRAINT "telegram_chat_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."telegram_pending"
    ADD CONSTRAINT "telegram_pending_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."telegram_processed_updates"
    ADD CONSTRAINT "telegram_processed_updates_pkey" PRIMARY KEY ("update_id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."turnover_verification"
    ADD CONSTRAINT "turnover_verification_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."turnover_verification"
    ADD CONSTRAINT "turnover_verification_property_id_checkout_date_key" UNIQUE ("property_id", "checkout_date");



CREATE INDEX "admin_auth_attempts_ip_time_idx" ON "public"."admin_auth_attempts" USING "btree" ("ip_hash", "attempted_at" DESC);



CREATE INDEX "idx_airbnb_reservations_checkin" ON "public"."airbnb_reservations" USING "btree" ("checkin_date");



CREATE INDEX "idx_airbnb_reservations_guest_id" ON "public"."airbnb_reservations" USING "btree" ("guest_id");



CREATE INDEX "idx_airbnb_reservations_status" ON "public"."airbnb_reservations" USING "btree" ("status");



CREATE INDEX "idx_airbnb_txn_confcode" ON "public"."airbnb_transactions" USING "btree" ("confirmation_code");



CREATE INDEX "idx_airbnb_txn_date" ON "public"."airbnb_transactions" USING "btree" ("txn_date");



CREATE INDEX "idx_airbnb_txn_enddate" ON "public"."airbnb_transactions" USING "btree" ("end_date");



CREATE INDEX "idx_airbnb_txn_rowtype" ON "public"."airbnb_transactions" USING "btree" ("row_type");



CREATE INDEX "idx_booking_inquiries_dates" ON "public"."booking_inquiries" USING "btree" ("checkin_date", "checkout_date");



CREATE INDEX "idx_booking_inquiries_guest" ON "public"."booking_inquiries" USING "btree" ("guest_id") WHERE ("guest_id" IS NOT NULL);



CREATE INDEX "idx_booking_inquiries_status" ON "public"."booking_inquiries" USING "btree" ("status");



CREATE INDEX "idx_calendar_events_checkin" ON "public"."calendar_events" USING "btree" ("property_id", "checkin_date") WHERE ("status" <> 'cancelled'::"text");



CREATE INDEX "idx_calendar_events_checkout" ON "public"."calendar_events" USING "btree" ("property_id", "checkout_date") WHERE ("status" <> 'cancelled'::"text");



CREATE INDEX "idx_calendar_events_property_dates" ON "public"."calendar_events" USING "btree" ("property_id", "checkin_date", "checkout_date");



CREATE INDEX "idx_cleaning_sessions_unpaid" ON "public"."cleaning_sessions" USING "btree" ("property_id", "cleaned_at" DESC) WHERE ("fee_paid_at" IS NULL);



CREATE INDEX "idx_dining_property" ON "public"."dining_spots" USING "btree" ("property_id");



CREATE INDEX "idx_guests_email" ON "public"."guests" USING "btree" ("property_id", "email") WHERE ("email" IS NOT NULL);



CREATE UNIQUE INDEX "idx_guests_phone_unique" ON "public"."guests" USING "btree" ("property_id", "phone") WHERE ("phone" IS NOT NULL);



CREATE INDEX "idx_pois_property" ON "public"."pois" USING "btree" ("property_id");



CREATE INDEX "idx_tch_chat_time" ON "public"."telegram_chat_history" USING "btree" ("chat_id", "created_at" DESC);



CREATE INDEX "idx_transactions_booking" ON "public"."transactions" USING "btree" ("booking_id") WHERE ("booking_id" IS NOT NULL);



CREATE INDEX "idx_transactions_property_date" ON "public"."transactions" USING "btree" ("property_id", "transaction_date" DESC);



CREATE INDEX "idx_transactions_review" ON "public"."transactions" USING "btree" ("status") WHERE ("status" = 'pending_review'::"text");



CREATE INDEX "idx_transactions_type_category" ON "public"."transactions" USING "btree" ("txn_type", "category");



CREATE INDEX "inventory_audit_log_created_idx" ON "public"."inventory_audit_log" USING "btree" ("created_at" DESC);



CREATE INDEX "inventory_items_name_trgm" ON "public"."inventory_items" USING "gin" ("name" "public"."gin_trgm_ops");



CREATE INDEX "inventory_usage_item_date_idx" ON "public"."inventory_usage" USING "btree" ("item_id", "session_date" DESC);



CREATE INDEX "kb_documents_applies_to_idx" ON "public"."kb_documents" USING "gin" ("applies_to");



CREATE INDEX "kb_documents_fts_idx" ON "public"."kb_documents" USING "gin" ("fts");



CREATE INDEX "kb_documents_path_idx" ON "public"."kb_documents" USING "btree" ("path");



CREATE INDEX "kb_documents_status_idx" ON "public"."kb_documents" USING "btree" ("status");



CREATE INDEX "kb_documents_tags_idx" ON "public"."kb_documents" USING "gin" ("tags");



CREATE INDEX "ops_notices_date_active_idx" ON "public"."ops_notices" USING "btree" ("property_id", "effective_date", "is_active");



CREATE INDEX "telegram_pending_chat_idx" ON "public"."telegram_pending" USING "btree" ("chat_id");



CREATE INDEX "telegram_pending_expires_idx" ON "public"."telegram_pending" USING "btree" ("expires_at");



CREATE UNIQUE INDEX "uq_transactions_income_external_ref" ON "public"."transactions" USING "btree" ("external_ref", "source") WHERE (("external_ref" IS NOT NULL) AND ("txn_type" = 'income'::"text"));



CREATE UNIQUE INDEX "uq_transactions_refund_external_ref" ON "public"."transactions" USING "btree" ("external_ref", "refund_rail") WHERE (("external_ref" IS NOT NULL) AND ("source" = 'refund'::"text") AND ("status" <> 'void'::"text"));



CREATE OR REPLACE TRIGGER "inventory_items_updated_at" BEFORE UPDATE ON "public"."inventory_items" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "kb_documents_fts_trigger" BEFORE INSERT OR UPDATE OF "title", "tags", "applies_to", "triggers", "content", "summary" ON "public"."kb_documents" FOR EACH ROW EXECUTE FUNCTION "public"."kb_documents_update_fts"();



CREATE OR REPLACE TRIGGER "properties_set_updated_at" BEFORE UPDATE ON "public"."properties" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_airbnb_transactions_updated_at" BEFORE UPDATE ON "public"."airbnb_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_booking_inquiries_updated_at" BEFORE UPDATE ON "public"."booking_inquiries" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_calendar_events_updated_at" BEFORE UPDATE ON "public"."calendar_events" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_dining_updated_at" BEFORE UPDATE ON "public"."dining_spots" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_employees_updated_at" BEFORE UPDATE ON "public"."employees" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_guests_updated_at" BEFORE UPDATE ON "public"."guests" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_ops_notices_updated_at" BEFORE UPDATE ON "public"."ops_notices" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_pois_updated_at" BEFORE UPDATE ON "public"."pois" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_transactions_updated_at" BEFORE UPDATE ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."expense_categories" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_cascade_manual_sections" BEFORE UPDATE ON "public"."cascade_manual_sections" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_turnover_verification" BEFORE UPDATE ON "public"."turnover_verification" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_airbnb_reservations_updated_at" BEFORE UPDATE ON "public"."airbnb_reservations" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_csv_row_reconcile" AFTER INSERT ON "public"."airbnb_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."trg_csv_row_reconcile"();



CREATE OR REPLACE TRIGGER "trg_direct_booking_cascade" AFTER UPDATE OF "status" ON "public"."transactions" FOR EACH ROW WHEN (("new"."source" = 'direct_booking'::"text")) EXECUTE FUNCTION "public"."fn_direct_booking_cascade"();



CREATE OR REPLACE TRIGGER "trg_reservation_cancel_sync" AFTER UPDATE OF "status" ON "public"."airbnb_reservations" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fn_reservation_cancel_sync"();



CREATE OR REPLACE TRIGGER "trg_reservation_reconcile" AFTER INSERT OR UPDATE OF "status", "host_payout" ON "public"."airbnb_reservations" FOR EACH ROW EXECUTE FUNCTION "public"."trg_reservation_reconcile"();



ALTER TABLE ONLY "public"."airbnb_email_events"
    ADD CONSTRAINT "airbnb_email_events_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."airbnb_reservations"
    ADD CONSTRAINT "airbnb_reservations_guest_id_fkey" FOREIGN KEY ("guest_id") REFERENCES "public"."guests"("id");



ALTER TABLE ONLY "public"."airbnb_reservations"
    ADD CONSTRAINT "airbnb_reservations_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."airbnb_transactions"
    ADD CONSTRAINT "airbnb_transactions_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."booking_inquiries"
    ADD CONSTRAINT "booking_inquiries_guest_id_fkey" FOREIGN KEY ("guest_id") REFERENCES "public"."guests"("id");



ALTER TABLE ONLY "public"."booking_inquiries"
    ADD CONSTRAINT "booking_inquiries_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."calendar_events"
    ADD CONSTRAINT "calendar_events_linked_reservation_id_fkey" FOREIGN KEY ("linked_reservation_id") REFERENCES "public"."airbnb_reservations"("id");



ALTER TABLE ONLY "public"."calendar_events"
    ADD CONSTRAINT "calendar_events_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."calendar_sync_log"
    ADD CONSTRAINT "calendar_sync_log_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."cascade_manual_sections"
    ADD CONSTRAINT "cascade_manual_sections_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."cleaner_rate_schedule"
    ADD CONSTRAINT "cleaner_rate_schedule_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."cleaning_diagnostics"
    ADD CONSTRAINT "cleaning_diagnostics_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."cleaning_diagnostics"
    ADD CONSTRAINT "cleaning_diagnostics_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."cleaning_sessions"("id");



ALTER TABLE ONLY "public"."cleaning_sessions"
    ADD CONSTRAINT "cleaning_sessions_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."cleaning_sessions"
    ADD CONSTRAINT "cleaning_sessions_fee_txn_fk" FOREIGN KEY ("fee_txn_id") REFERENCES "public"."transactions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."cleaning_sessions"
    ADD CONSTRAINT "cleaning_sessions_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."dining_spots"
    ADD CONSTRAINT "dining_spots_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."expense_categories"
    ADD CONSTRAINT "expense_categories_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."guests"
    ADD CONSTRAINT "guests_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."inventory_purchases"
    ADD CONSTRAINT "inventory_purchases_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."inventory_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_usage"
    ADD CONSTRAINT "inventory_usage_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."inventory_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."meter_readings"
    ADD CONSTRAINT "meter_readings_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."meter_readings"
    ADD CONSTRAINT "meter_readings_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."cleaning_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ops_notices"
    ADD CONSTRAINT "ops_notices_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."pois"
    ADD CONSTRAINT "pois_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."returning_guest_alerts"
    ADD CONSTRAINT "returning_guest_alerts_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."booking_inquiries"("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."turnover_verification"
    ADD CONSTRAINT "turnover_verification_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."turnover_verification"
    ADD CONSTRAINT "turnover_verification_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."cleaning_sessions"("id");



CREATE POLICY "admin_all_employees" ON "public"."employees" TO "authenticated" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'admin'::"text")) WITH CHECK (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'admin'::"text"));



ALTER TABLE "public"."admin_auth_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."airbnb_email_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."airbnb_reservations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "airbnb_reservations_owner_admin_all" ON "public"."airbnb_reservations" TO "authenticated" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."airbnb_transactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "airbnb_txn_owner_admin_all" ON "public"."airbnb_transactions" TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "anon all" ON "public"."inventory_items" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon all" ON "public"."inventory_purchases" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon insert" ON "public"."cleaning_sessions" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "anon insert" ON "public"."inventory_audit_log" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "anon insert" ON "public"."inventory_usage" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "anon insert" ON "public"."meter_readings" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "anon select" ON "public"."cleaning_sessions" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon select" ON "public"."dining_spots" FOR SELECT TO "anon" USING (("is_active" = true));



CREATE POLICY "anon select" ON "public"."inventory_audit_log" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon select" ON "public"."inventory_usage" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon select" ON "public"."meter_readings" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon select" ON "public"."pois" FOR SELECT TO "anon" USING (("is_active" = true));



CREATE POLICY "anon select public" ON "public"."app_settings" FOR SELECT TO "anon" USING ((("key" !~~* '%token%'::"text") AND ("key" !~~* '%secret%'::"text") AND ("key" !~~* '%pin_hash%'::"text") AND ("key" !~~* '%ical%'::"text") AND ("key" !~~* '%chat_id%'::"text") AND ("key" <> ALL (ARRAY['email_recipients'::"text", 'users'::"text"]))));



CREATE POLICY "anon_select_active_properties" ON "public"."properties" FOR SELECT TO "anon" USING (("is_active" = true));



ALTER TABLE "public"."app_secrets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "auth all" ON "public"."app_settings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "auth all" ON "public"."dining_spots" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "auth all" ON "public"."pois" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "auth read active kb" ON "public"."kb_documents" FOR SELECT TO "authenticated" USING (("status" = 'active'::"text"));



CREATE POLICY "authenticated all" ON "public"."inventory_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated all" ON "public"."inventory_purchases" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_all_cleaning_sessions" ON "public"."cleaning_sessions" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_all_meter_readings" ON "public"."meter_readings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_all_properties" ON "public"."properties" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."booking_inquiries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "booking_inquiries_owner_admin_select" ON "public"."booking_inquiries" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."calendar_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "calendar_events_owner_admin_all" ON "public"."calendar_events" TO "authenticated" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."calendar_sync_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "calendar_sync_log_owner_admin_all" ON "public"."calendar_sync_log" TO "authenticated" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."cascade_manual_sections" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cd_admin_only" ON "public"."cleaning_diagnostics" FOR SELECT TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = 'admin'::"text"));



CREATE POLICY "cleaner_rate_owner_admin_all" ON "public"."cleaner_rate_schedule" TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."cleaner_rate_schedule" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cleaning_diagnostics" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cleaning_sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dining_admin_all" ON "public"."dining_spots" TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "dining_anon_read" ON "public"."dining_spots" FOR SELECT TO "anon" USING (("is_active" = true));



ALTER TABLE "public"."dining_spots" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "email_events_owner_admin_read" ON "public"."airbnb_email_events" FOR SELECT TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."employees" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expense_categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "expense_categories_owner_admin_all" ON "public"."expense_categories" TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."guests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "guests_owner_admin_all" ON "public"."guests" TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."inventory_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_purchases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_usage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."kb_documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "manual_sections_admin_all" ON "public"."cascade_manual_sections" TO "authenticated" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'admin'::"text")) WITH CHECK (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'admin'::"text"));



CREATE POLICY "manual_sections_owner_read" ON "public"."cascade_manual_sections" FOR SELECT TO "authenticated" USING ((((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'owner'::"text") AND ("min_role" = ANY (ARRAY['staff'::"text", 'owner'::"text"])) AND ("is_active" = true)));



CREATE POLICY "manual_sections_staff_read" ON "public"."cascade_manual_sections" FOR SELECT TO "authenticated" USING ((((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'staff'::"text") AND ("min_role" = 'staff'::"text") AND ("is_active" = true)));



ALTER TABLE "public"."meter_readings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ops_notices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ops_notices_anon_insert" ON "public"."ops_notices" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "ops_notices_anon_select" ON "public"."ops_notices" FOR SELECT TO "anon" USING (("is_active" = true));



CREATE POLICY "ops_notices_auth_all" ON "public"."ops_notices" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "owner_select_employees" ON "public"."employees" FOR SELECT TO "authenticated" USING (((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text") = 'owner'::"text"));



ALTER TABLE "public"."pois" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pois_admin_all" ON "public"."pois" TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



CREATE POLICY "pois_anon_read" ON "public"."pois" FOR SELECT TO "anon" USING (("is_active" = true));



ALTER TABLE "public"."properties" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."reconciliation_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "returning_alerts_owner_admin_read" ON "public"."returning_guest_alerts" FOR SELECT TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."returning_guest_alerts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service role full access" ON "public"."airbnb_email_events" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service role full access" ON "public"."airbnb_reservations" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_role_all" ON "public"."reconciliation_log" USING (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "service_role_all" ON "public"."telegram_chat_history" USING (true) WITH CHECK (true);



ALTER TABLE "public"."telegram_chat_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."telegram_pending" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."telegram_processed_updates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transactions_owner_admin_all" ON "public"."transactions" TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"]))) WITH CHECK ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



ALTER TABLE "public"."turnover_verification" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tv_owner_admin_read" ON "public"."turnover_verification" FOR SELECT TO "authenticated" USING ((( SELECT (("auth"."jwt"() -> 'app_metadata'::"text") ->> 'role'::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text"])));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_inventory_purchase"("p_item_id" "uuid", "p_qty" numeric, "p_unit_cost" numeric, "p_supplier" "text", "p_purchased_at" "date", "p_txn_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_inventory_purchase"("p_item_id" "uuid", "p_qty" numeric, "p_unit_cost" numeric, "p_supplier" "text", "p_purchased_at" "date", "p_txn_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_inventory_purchase"("p_item_id" "uuid", "p_qty" numeric, "p_unit_cost" numeric, "p_supplier" "text", "p_purchased_at" "date", "p_txn_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."browse_kb"("filter_tags" "text"[], "filter_applies_to" "text"[], "max_results" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."browse_kb"("filter_tags" "text"[], "filter_applies_to" "text"[], "max_results" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."browse_kb"("filter_tags" "text"[], "filter_applies_to" "text"[], "max_results" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."check_availability"("p_checkin" "date", "p_checkout" "date", "p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."check_availability"("p_checkin" "date", "p_checkout" "date", "p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_availability"("p_checkin" "date", "p_checkout" "date", "p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."ensure_income_transaction"("p_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_income_transaction"("p_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_income_transaction"("p_code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_direct_booking_cascade"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_direct_booking_cascade"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_direct_booking_cascade"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_active_staff"("p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_active_staff"("p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_active_staff"("p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_booking_for_date"("p_date" "date", "p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_booking_for_date"("p_date" "date", "p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_booking_for_date"("p_date" "date", "p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_data_integrity_report"("p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_data_integrity_report"("p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_data_integrity_report"("p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_datahealth_report"("p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_datahealth_report"("p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_datahealth_report"("p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_employee_history"("p_employee_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_employee_history"("p_employee_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_employee_history"("p_employee_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_finance_summary"("p_month" "date", "p_property_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_finance_summary"("p_month" "date", "p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_finance_summary"("p_month" "date", "p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_guest_history"("p_full_name" "text", "p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_guest_history"("p_full_name" "text", "p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_guest_history"("p_full_name" "text", "p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_kb_document"("p_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_kb_document"("p_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_kb_document"("p_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_missed_cleanings"("p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_missed_cleanings"("p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_missed_cleanings"("p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_usage_medians"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_usage_medians"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_usage_medians"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_welcome_info"("p_date" "date", "p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_welcome_info"("p_date" "date", "p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_welcome_info"("p_date" "date", "p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."kb_documents_update_fts"() TO "anon";
GRANT ALL ON FUNCTION "public"."kb_documents_update_fts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."kb_documents_update_fts"() TO "service_role";



GRANT ALL ON FUNCTION "public"."log_returning_guest_alert"("p_guest_name" "text", "p_current_checkin" "date", "p_current_checkout" "date", "p_current_nights" integer, "p_previous_stays" integer, "p_total_nights" integer, "p_last_stay_checkin" "date", "p_last_stay_checkout" "date", "p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."log_returning_guest_alert"("p_guest_name" "text", "p_current_checkin" "date", "p_current_checkout" "date", "p_current_nights" integer, "p_previous_stays" integer, "p_total_nights" integer, "p_last_stay_checkin" "date", "p_last_stay_checkout" "date", "p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_returning_guest_alert"("p_guest_name" "text", "p_current_checkin" "date", "p_current_checkout" "date", "p_current_nights" integer, "p_previous_stays" integer, "p_total_nights" integer, "p_last_stay_checkin" "date", "p_last_stay_checkout" "date", "p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."match_inventory_item"("p_name" "text", "p_limit" integer, "p_threshold" real, "p_consumable_only" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."match_inventory_item"("p_name" "text", "p_limit" integer, "p_threshold" real, "p_consumable_only" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_inventory_item"("p_name" "text", "p_limit" integer, "p_threshold" real, "p_consumable_only" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."reconcile_all_completed_reservations"() TO "anon";
GRANT ALL ON FUNCTION "public"."reconcile_all_completed_reservations"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reconcile_all_completed_reservations"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reconcile_reservation_from_transactions"("p_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reconcile_reservation_from_transactions"("p_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reconcile_reservation_from_transactions"("p_code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_guest_stats"("p_guest_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_guest_stats"("p_guest_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_guest_stats"("p_guest_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_kb"("query_text" "text", "max_results" integer, "filter_tags" "text"[], "filter_applies_to" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."search_kb"("query_text" "text", "max_results" integer, "filter_tags" "text"[], "filter_applies_to" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_kb"("query_text" "text", "max_results" integer, "filter_tags" "text"[], "filter_applies_to" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."search_kb_full"("query_text" "text", "max_results" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."search_kb_full"("query_text" "text", "max_results" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_kb_full"("query_text" "text", "max_results" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_csv_row_reconcile"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_csv_row_reconcile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_csv_row_reconcile"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fn_reservation_cancel_sync"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fn_reservation_cancel_sync"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fn_reservation_cancel_sync"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_reservation_reconcile"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_reservation_reconcile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_reservation_reconcile"() TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_kb_document"("p_path" "text", "p_title" "text", "p_content" "text", "p_tags" "text"[], "p_applies_to" "text"[], "p_triggers" "text"[], "p_summary" "text", "p_doc_type" "text", "p_github_sha" "text", "p_github_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_kb_document"("p_path" "text", "p_title" "text", "p_content" "text", "p_tags" "text"[], "p_applies_to" "text"[], "p_triggers" "text"[], "p_summary" "text", "p_doc_type" "text", "p_github_sha" "text", "p_github_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_kb_document"("p_path" "text", "p_title" "text", "p_content" "text", "p_tags" "text"[], "p_applies_to" "text"[], "p_triggers" "text"[], "p_summary" "text", "p_doc_type" "text", "p_github_sha" "text", "p_github_url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."verify_admin_pin"("pin" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."verify_admin_pin"("pin" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."verify_admin_pin"("pin" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify_admin_pin"("pin" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."verify_admin_pin"("p_code" "text", "p_client" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."verify_admin_pin"("p_code" "text", "p_client" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."verify_admin_pin"("p_code" "text", "p_client" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify_admin_pin"("p_code" "text", "p_client" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."verify_booking"("p_checkin_date" "date", "p_initial" "text", "p_property_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."verify_booking"("p_checkin_date" "date", "p_initial" "text", "p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."verify_booking"("p_checkin_date" "date", "p_initial" "text", "p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify_booking"("p_checkin_date" "date", "p_initial" "text", "p_property_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."verify_turnover"("p_checkout_date" "date", "p_property_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."verify_turnover"("p_checkout_date" "date", "p_property_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify_turnover"("p_checkout_date" "date", "p_property_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."admin_auth_attempts" TO "anon";
GRANT ALL ON TABLE "public"."admin_auth_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_auth_attempts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."admin_auth_attempts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."admin_auth_attempts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."admin_auth_attempts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."airbnb_transactions" TO "anon";
GRANT ALL ON TABLE "public"."airbnb_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."airbnb_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."cleaner_rate_schedule" TO "anon";
GRANT ALL ON TABLE "public"."cleaner_rate_schedule" TO "authenticated";
GRANT ALL ON TABLE "public"."cleaner_rate_schedule" TO "service_role";



GRANT ALL ON TABLE "public"."airbnb_cleans" TO "anon";
GRANT ALL ON TABLE "public"."airbnb_cleans" TO "authenticated";
GRANT ALL ON TABLE "public"."airbnb_cleans" TO "service_role";



GRANT ALL ON TABLE "public"."airbnb_email_events" TO "anon";
GRANT ALL ON TABLE "public"."airbnb_email_events" TO "authenticated";
GRANT ALL ON TABLE "public"."airbnb_email_events" TO "service_role";



GRANT ALL ON TABLE "public"."airbnb_guest_summary" TO "anon";
GRANT ALL ON TABLE "public"."airbnb_guest_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."airbnb_guest_summary" TO "service_role";



GRANT ALL ON TABLE "public"."airbnb_monthly_revenue" TO "anon";
GRANT ALL ON TABLE "public"."airbnb_monthly_revenue" TO "authenticated";
GRANT ALL ON TABLE "public"."airbnb_monthly_revenue" TO "service_role";



GRANT ALL ON TABLE "public"."airbnb_reservations" TO "anon";
GRANT ALL ON TABLE "public"."airbnb_reservations" TO "authenticated";
GRANT ALL ON TABLE "public"."airbnb_reservations" TO "service_role";



GRANT ALL ON TABLE "public"."app_secrets" TO "anon";
GRANT ALL ON TABLE "public"."app_secrets" TO "authenticated";
GRANT ALL ON TABLE "public"."app_secrets" TO "service_role";



GRANT ALL ON TABLE "public"."app_settings" TO "anon";
GRANT ALL ON TABLE "public"."app_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."app_settings" TO "service_role";



GRANT ALL ON TABLE "public"."booking_inquiries" TO "anon";
GRANT ALL ON TABLE "public"."booking_inquiries" TO "authenticated";
GRANT ALL ON TABLE "public"."booking_inquiries" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."calendar_events" TO "anon";
GRANT ALL ON TABLE "public"."calendar_events" TO "authenticated";
GRANT ALL ON TABLE "public"."calendar_events" TO "service_role";



GRANT SELECT("uid") ON TABLE "public"."calendar_events" TO "anon";



GRANT SELECT("source") ON TABLE "public"."calendar_events" TO "anon";



GRANT SELECT("checkin_date") ON TABLE "public"."calendar_events" TO "anon";



GRANT SELECT("checkout_date") ON TABLE "public"."calendar_events" TO "anon";



GRANT SELECT("status") ON TABLE "public"."calendar_events" TO "anon";



GRANT ALL ON TABLE "public"."calendar_sync_log" TO "anon";
GRANT ALL ON TABLE "public"."calendar_sync_log" TO "authenticated";
GRANT ALL ON TABLE "public"."calendar_sync_log" TO "service_role";



GRANT ALL ON TABLE "public"."cascade_manual_sections" TO "anon";
GRANT ALL ON TABLE "public"."cascade_manual_sections" TO "authenticated";
GRANT ALL ON TABLE "public"."cascade_manual_sections" TO "service_role";



GRANT ALL ON TABLE "public"."cleaning_diagnostics" TO "anon";
GRANT ALL ON TABLE "public"."cleaning_diagnostics" TO "authenticated";
GRANT ALL ON TABLE "public"."cleaning_diagnostics" TO "service_role";



GRANT ALL ON TABLE "public"."cleaning_sessions" TO "anon";
GRANT ALL ON TABLE "public"."cleaning_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."cleaning_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."dining_spots" TO "anon";
GRANT ALL ON TABLE "public"."dining_spots" TO "authenticated";
GRANT ALL ON TABLE "public"."dining_spots" TO "service_role";



GRANT ALL ON TABLE "public"."employees" TO "anon";
GRANT ALL ON TABLE "public"."employees" TO "authenticated";
GRANT ALL ON TABLE "public"."employees" TO "service_role";



GRANT ALL ON TABLE "public"."expense_categories" TO "anon";
GRANT ALL ON TABLE "public"."expense_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."expense_categories" TO "service_role";



GRANT ALL ON TABLE "public"."guests" TO "anon";
GRANT ALL ON TABLE "public"."guests" TO "authenticated";
GRANT ALL ON TABLE "public"."guests" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."inventory_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_items" TO "anon";
GRANT ALL ON TABLE "public"."inventory_items" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_items" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_purchases" TO "anon";
GRANT ALL ON TABLE "public"."inventory_purchases" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_purchases" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_usage" TO "anon";
GRANT ALL ON TABLE "public"."inventory_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_usage" TO "service_role";



GRANT ALL ON TABLE "public"."kb_documents" TO "anon";
GRANT ALL ON TABLE "public"."kb_documents" TO "authenticated";
GRANT ALL ON TABLE "public"."kb_documents" TO "service_role";



GRANT ALL ON TABLE "public"."meter_readings" TO "anon";
GRANT ALL ON TABLE "public"."meter_readings" TO "authenticated";
GRANT ALL ON TABLE "public"."meter_readings" TO "service_role";



GRANT ALL ON TABLE "public"."ops_notices" TO "anon";
GRANT ALL ON TABLE "public"."ops_notices" TO "authenticated";
GRANT ALL ON TABLE "public"."ops_notices" TO "service_role";



GRANT ALL ON TABLE "public"."pois" TO "anon";
GRANT ALL ON TABLE "public"."pois" TO "authenticated";
GRANT ALL ON TABLE "public"."pois" TO "service_role";



GRANT ALL ON TABLE "public"."price_history_by_item" TO "anon";
GRANT ALL ON TABLE "public"."price_history_by_item" TO "authenticated";
GRANT ALL ON TABLE "public"."price_history_by_item" TO "service_role";



GRANT ALL ON TABLE "public"."properties" TO "anon";
GRANT ALL ON TABLE "public"."properties" TO "authenticated";
GRANT ALL ON TABLE "public"."properties" TO "service_role";



GRANT ALL ON TABLE "public"."reconciliation_log" TO "anon";
GRANT ALL ON TABLE "public"."reconciliation_log" TO "authenticated";
GRANT ALL ON TABLE "public"."reconciliation_log" TO "service_role";



GRANT ALL ON TABLE "public"."returning_guest_alerts" TO "anon";
GRANT ALL ON TABLE "public"."returning_guest_alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."returning_guest_alerts" TO "service_role";



GRANT ALL ON TABLE "public"."telegram_chat_history" TO "anon";
GRANT ALL ON TABLE "public"."telegram_chat_history" TO "authenticated";
GRANT ALL ON TABLE "public"."telegram_chat_history" TO "service_role";



GRANT ALL ON TABLE "public"."telegram_pending" TO "anon";
GRANT ALL ON TABLE "public"."telegram_pending" TO "authenticated";
GRANT ALL ON TABLE "public"."telegram_pending" TO "service_role";



GRANT ALL ON TABLE "public"."telegram_processed_updates" TO "anon";
GRANT ALL ON TABLE "public"."telegram_processed_updates" TO "authenticated";
GRANT ALL ON TABLE "public"."telegram_processed_updates" TO "service_role";



GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";



GRANT ALL ON TABLE "public"."turnover_verification" TO "anon";
GRANT ALL ON TABLE "public"."turnover_verification" TO "authenticated";
GRANT ALL ON TABLE "public"."turnover_verification" TO "service_role";



GRANT ALL ON TABLE "public"."v_canonical_ledger" TO "anon";
GRANT ALL ON TABLE "public"."v_canonical_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."v_canonical_ledger" TO "service_role";



GRANT ALL ON TABLE "public"."v_direct_bookings" TO "anon";
GRANT ALL ON TABLE "public"."v_direct_bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."v_direct_bookings" TO "service_role";



GRANT ALL ON TABLE "public"."v_direct_state_desync" TO "anon";
GRANT ALL ON TABLE "public"."v_direct_state_desync" TO "authenticated";
GRANT ALL ON TABLE "public"."v_direct_state_desync" TO "service_role";



GRANT ALL ON TABLE "public"."v_finance_orphans" TO "anon";
GRANT ALL ON TABLE "public"."v_finance_orphans" TO "authenticated";
GRANT ALL ON TABLE "public"."v_finance_orphans" TO "service_role";



GRANT ALL ON TABLE "public"."v_guest_refunds" TO "anon";
GRANT ALL ON TABLE "public"."v_guest_refunds" TO "authenticated";
GRANT ALL ON TABLE "public"."v_guest_refunds" TO "service_role";



GRANT ALL ON TABLE "public"."v_income_canonical" TO "anon";
GRANT ALL ON TABLE "public"."v_income_canonical" TO "authenticated";
GRANT ALL ON TABLE "public"."v_income_canonical" TO "service_role";



GRANT ALL ON TABLE "public"."v_status_desync" TO "anon";
GRANT ALL ON TABLE "public"."v_status_desync" TO "authenticated";
GRANT ALL ON TABLE "public"."v_status_desync" TO "service_role";



GRANT ALL ON TABLE "public"."v_status_desync_wide" TO "anon";
GRANT ALL ON TABLE "public"."v_status_desync_wide" TO "authenticated";
GRANT ALL ON TABLE "public"."v_status_desync_wide" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







