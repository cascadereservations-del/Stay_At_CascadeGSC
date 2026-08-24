
CREATE TABLE public.transactions (
  -- standard columns (conventions)
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  property_id   uuid NOT NULL DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' REFERENCES public.properties(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  -- ledger semantics
  txn_type      text NOT NULL CHECK (txn_type IN ('income','expense')),
  category      text NOT NULL,
  status        text NOT NULL DEFAULT 'confirmed' CHECK (status IN ('pending_review','confirmed','void')),
  source        text NOT NULL DEFAULT 'manual' CHECK (source IN ('telegram','ocr','booking','manual','import')),

  -- money
  transaction_date date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Manila')::date,
  gross_amount  numeric(12,2) NOT NULL CHECK (gross_amount >= 0),
  currency      text NOT NULL DEFAULT 'PHP',

  -- BIR-ready (nullable until registration; capture-now, file-later)
  or_number     text,
  payee_name    text,
  payee_tin     text,
  tax_base      numeric(12,2),
  tax_amount    numeric(12,2),
  tax_treatment text CHECK (tax_treatment IS NULL OR tax_treatment IN ('vat_exempt','zero_rated','vatable','non_vat')),

  -- receipts + OCR pipeline
  receipt_image_path text,
  ocr_confidence     numeric(5,2),
  ocr_raw            jsonb,

  -- linkage + provenance
  booking_id    uuid REFERENCES public.booking_inquiries(id),
  logged_by     text,
  notes         text
);

-- updated_at trigger (reuse existing convention function)
CREATE TRIGGER set_transactions_updated_at
  BEFORE UPDATE ON public.transactions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- indexes
CREATE INDEX idx_transactions_property_date ON public.transactions (property_id, transaction_date DESC);
CREATE INDEX idx_transactions_type_category ON public.transactions (txn_type, category);
CREATE INDEX idx_transactions_review        ON public.transactions (status) WHERE status = 'pending_review';
CREATE INDEX idx_transactions_booking       ON public.transactions (booking_id) WHERE booking_id IS NOT NULL;

-- RLS: finance is restricted (conventions) — owner/admin only; service role (Edge Functions) bypasses
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY transactions_owner_admin_all ON public.transactions
  FOR ALL TO authenticated
  USING      ( (auth.jwt() -> 'user_metadata' ->> 'role') IN ('owner','admin') )
  WITH CHECK ( (auth.jwt() -> 'user_metadata' ->> 'role') IN ('owner','admin') );

COMMENT ON TABLE public.transactions IS 'Unified financial ledger (income + expense). Sources: telegram expense logging, OCR receipts, booking income, manual. BIR fields nullable until registration.';
;
