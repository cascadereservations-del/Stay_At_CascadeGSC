
CREATE OR REPLACE VIEW public.v_status_desync AS
SELECT DISTINCT
  ce.id                AS calendar_event_id,
  ce.uid,
  ce.property_id,
  ar.id                AS reservation_id,
  ar.confirmation_code,
  ar.guest_name,
  ce.status            AS cal_status,
  ar.status            AS rsv_status,
  ce.checkin_date      AS cal_checkin,
  ar.checkin_date      AS rsv_checkin,
  ce.checkout_date     AS cal_checkout,
  ar.checkout_date     AS rsv_checkout,
  ce.recon_status,
  CASE
    WHEN ce.status = 'cancelled' AND ar.status NOT IN ('cancelled','rejected')
      THEN 'cal_cancelled_rsv_active'
    WHEN ar.status = 'cancelled' AND ce.status NOT IN ('cancelled','rejected')
      THEN 'rsv_cancelled_cal_active'
    WHEN ABS(ce.checkin_date - ar.checkin_date) > 2
      THEN 'date_mismatch_checkin'
    WHEN ABS(ce.checkout_date - ar.checkout_date) > 2
      THEN 'date_mismatch_checkout'
    ELSE 'other'
  END AS desync_reason
FROM public.calendar_events ce
JOIN public.airbnb_reservations ar
  ON ce.property_id = ar.property_id
  AND (
    ce.linked_reservation_id = ar.id
    OR upper(ce.uid) LIKE '%' || upper(ar.confirmation_code) || '%'
  )
WHERE (
  (ce.status = 'cancelled' AND ar.status NOT IN ('cancelled', 'rejected'))
  OR (ar.status = 'cancelled' AND ce.status NOT IN ('cancelled', 'rejected'))
  OR ABS(ce.checkin_date - ar.checkin_date) > 2
  OR ABS(ce.checkout_date - ar.checkout_date) > 2
);

-- Grant read to authenticated and anon (view inherits underlying table RLS)
GRANT SELECT ON public.v_status_desync TO authenticated;
GRANT SELECT ON public.v_status_desync TO anon;
;
