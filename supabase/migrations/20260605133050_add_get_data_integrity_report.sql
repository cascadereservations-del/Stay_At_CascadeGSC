CREATE OR REPLACE FUNCTION public.get_data_integrity_report(p_property_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
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
$function$;;
