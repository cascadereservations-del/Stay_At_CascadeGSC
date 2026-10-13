// Lane C (s81): upload-photo records the sha256 of the bytes it stored, so a payment screenshot's hash is the server's own figure and not a client's claim.
// staff_pay_admin_settle_v1 reads it from staff_upload_hashes. Best effort: a failure here never fails the upload (the checklist and guest ID uploads
// must keep working); a screenshot without a recorded hash simply cannot settle a payment request.
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource));
  return Array.from(d, (b) => b.toString(16).padStart(2, '0')).join('');
}

// deno-lint-ignore no-explicit-any
export async function recordUploadHash(db: any, row: { path: string; sha256: string; uploaded_by: string }): Promise<boolean> {
  try {
    const { error } = await db.from('staff_upload_hashes').insert(row);
    if (error) { console.warn('upload hash not recorded:', String(error.code ?? error.message ?? error).slice(0, 80)); return false; }
    return true;
  } catch (e) {
    console.warn('upload hash not recorded:', String((e as Error)?.message ?? e).slice(0, 80));
    return false;
  }
}
