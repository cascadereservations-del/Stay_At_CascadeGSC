create or replace view v_direct_state_desync as
select bi.id, bi.guest_name, bi.checkin_date, bi.status inq_status,
       ce.status cal_status, t.status txn_status
from booking_inquiries bi
left join calendar_events ce on ce.uid = 'direct:'||bi.id
left join transactions   t  on t.external_ref = bi.id::text
where bi.source='direct'
  and (
    (bi.status='pending'   and (ce.status<>'blocked'   or t.status<>'pending_review')) or
    (bi.status='confirmed' and (ce.status<>'confirmed' or t.status<>'confirmed'))       or
    (bi.status='cancelled' and (ce.status<>'cancelled' or t.status<>'void'))
  );

create or replace view v_status_desync_wide as
select ce.guest_name, ce.checkin_date cal_in, r.checkin_date rsv_in,
       ce.checkout_date cal_out, r.checkout_date rsv_out,
       ce.nights cal_n, r.nights rsv_n, r.confirmation_code,
       (ce.linked_reservation_id is not null) linked
from calendar_events ce
join airbnb_reservations r on lower(r.guest_name)=lower(ce.guest_name)
where ce.source='airbnb'
  and (ce.checkin_date<>r.checkin_date or ce.checkout_date<>r.checkout_date
       or coalesce(ce.nights,0)<>coalesce(r.nights,0));;
