const nonContentTags = new Set(['SCRIPT', 'STYLE', 'LINK']);

export function bodyPortals(rootElement) {
  return Array.from(rootElement.ownerDocument.body.children).filter(element =>
    element !== rootElement && !nonContentTags.has(element.tagName));
}

export function contentHeight(rootElement, portals) {
  const rootRect = rootElement.getBoundingClientRect();
  const view = rootElement.ownerDocument.defaultView;
  const scrollY = view.scrollY;
  let height = rootRect.bottom + scrollY;
  for (const portal of portals) {
    const style = view.getComputedStyle(portal);
    if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') continue;
    const rect = portal.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    height = Math.max(height, rect.bottom + scrollY);
    // FloatingUI may initially flip a calendar above a short inline viewport.
    // Reserve enough room below the root so its next placement can be visible.
    // Do not use document.scrollHeight: viewport-sized overlays would make it
    // self-referential as native code resizes the attachment.
    if (rect.top < 0) height = Math.max(height, rootRect.bottom + scrollY + rect.height + 16);
  }
  return Math.ceil(height);
}
