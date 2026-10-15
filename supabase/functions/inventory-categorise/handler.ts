// STUB (RED run): replaced by the real handler in the next commit.
export const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
export const CORS_H = {};
export function makeHandler(_o: { now?: () => Date; timeoutMs?: number } = {}) {
  return (_req: Request): Promise<Response> => Promise.resolve(new Response('not implemented', { status: 501 }));
}
