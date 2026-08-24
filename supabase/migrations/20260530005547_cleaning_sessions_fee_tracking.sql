
ALTER TABLE public.cleaning_sessions
  ADD COLUMN IF NOT EXISTS cleaning_type text,
  ADD COLUMN IF NOT EXISTS fee_amount   numeric,
  ADD COLUMN IF NOT EXISTS fee_paid_at  timestamptz,
  ADD COLUMN IF NOT EXISTS fee_txn_id   uuid,
  ADD COLUMN IF NOT EXISTS fee_acked_at timestamptz;

UPDATE public.cleaning_sessions SET cleaning_type = 'turnover' WHERE cleaning_type IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'cleaning_sessions_fee_txn_fk'
  ) THEN
    ALTER TABLE public.cleaning_sessions
      ADD CONSTRAINT cleaning_sessions_fee_txn_fk
      FOREIGN KEY (fee_txn_id) REFERENCES public.transactions(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_cleaning_sessions_unpaid
  ON public.cleaning_sessions (property_id, cleaned_at DESC)
  WHERE fee_paid_at IS NULL;
;
