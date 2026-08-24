
ALTER TABLE public.transactions DROP CONSTRAINT IF EXISTS transactions_source_check;
ALTER TABLE public.transactions ADD CONSTRAINT transactions_source_check
  CHECK (source = ANY (ARRAY[
    'telegram','ocr','booking','manual','import','airbnb',
    'airbnb_email','airbnb_payout_email','direct_booking','cleaner_fee'
  ]));
;
