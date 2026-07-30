/**
 * Recovery blocks are keyed by the exact principal storage key. Switching
 * accounts must never unblock damaged data belonging to another principal.
 */
export class PersistenceBlockRegistry {
  readonly #keys = new Set<string>();

  block(key: string): void {
    this.#keys.add(key);
  }

  resolve(key: string): void {
    this.#keys.delete(key);
  }

  isBlocked(key: string): boolean {
    return this.#keys.has(key);
  }
}
