/** Durable user documents: only report saved after the transaction commits. */
export async function workspaceStore(mode: 'read' | 'write', value?: unknown, key = 'current'): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open('cap-preparation', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('workspace');
    open.onerror = () => reject(new Error('Browser storage is unavailable. Export your PGN to keep a copy.'));
    open.onblocked = () => reject(new Error('Close other Chess Auto Prep tabs and retry saving.'));
    open.onsuccess = () => {
      const db = open.result;
      const tx = db.transaction('workspace', mode === 'write' ? 'readwrite' : 'readonly');
      const request = mode === 'write' ? tx.objectStore('workspace').put(value, key) : tx.objectStore('workspace').get(key);
      tx.oncomplete = () => { db.close(); resolve(request.result); };
      tx.onabort = tx.onerror = () => { db.close(); reject(new Error('Could not save in this browser. Export your PGN before closing.')); };
    };
  });
}
