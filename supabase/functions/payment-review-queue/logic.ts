export type QueueRequest = { propertyId: string; limit: number };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function parseQueueRequest(url: URL): QueueRequest | null {
  const propertyId = (url.searchParams.get('property_id') ?? '').trim();
  const rawLimit = url.searchParams.get('limit') ?? '50';
  if (!UUID.test(propertyId) || !/^\d{1,3}$/.test(rawLimit)) return null;
  const limit = Number(rawLimit);
  return limit >= 1 && limit <= 100 ? { propertyId, limit } : null;
}

export function queueErrorStatus(code: string | undefined): number {
  if (code === '42501') return 403;
  if (code === '22023') return 400;
  return 503;
}
