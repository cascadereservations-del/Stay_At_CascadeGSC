export function cronSecretMatches(
  configured: string | undefined,
  supplied: string | null,
): boolean {
  if (!configured || !supplied || configured.length !== supplied.length) return false;
  let difference = 0;
  for (let index = 0; index < configured.length; index += 1) {
    difference |= configured.charCodeAt(index) ^ supplied.charCodeAt(index);
  }
  return difference === 0;
}
