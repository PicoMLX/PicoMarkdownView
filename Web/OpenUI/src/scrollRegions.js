const scrollableOverflow = new Set(['auto', 'scroll']);
const clippedOverflow = new Set(['auto', 'scroll', 'hidden', 'clip']);
const edgeTolerance = 1;
const maximumRegions = 64;

function visibleRegion(element, view) {
  const style = view.getComputedStyle(element);
  if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse'
      || style.pointerEvents === 'none') return null;
  if (element.clientHeight <= 0 || element.scrollHeight <= element.clientHeight + edgeTolerance) return null;
  const rect = element.getBoundingClientRect();
  let left = Math.max(0, rect.left), top = Math.max(0, rect.top);
  let right = Math.min(view.innerWidth, rect.right), bottom = Math.min(view.innerHeight, rect.bottom);
  // A scrollable descendant may extend beneath an ancestor's clipped viewport.
  // body/html overflow is the page viewport, already applied above.
  for (let parent = element.parentElement; parent && parent !== element.ownerDocument.body; parent = parent.parentElement) {
    const parentStyle = view.getComputedStyle(parent);
    const parentRect = parent.getBoundingClientRect();
    if (clippedOverflow.has(parentStyle.overflowX)) {
      left = Math.max(left, parentRect.left); right = Math.min(right, parentRect.right);
    }
    if (clippedOverflow.has(parentStyle.overflowY)) {
      top = Math.max(top, parentRect.top); bottom = Math.min(bottom, parentRect.bottom);
    }
  }
  const width = right - left, height = bottom - top;
  if (![left, top, width, height].every(Number.isFinite) || width <= 0 || height <= 0) return null;
  return {
    x: left, y: top, width, height,
    canScrollUp: element.scrollTop > edgeTolerance,
    canScrollDown: element.scrollTop + element.clientHeight < element.scrollHeight - edgeTolerance,
  };
}

export function createScrollRegionReporter(document, sourceIdentity, postRegions) {
  const view = document.defaultView;
  let candidates = new Set(), dirty = true, timer = 0, force = false, last = null;
  const observer = new ResizeObserver(() => schedule());
  function rescan() {
    const next = new Set(Array.from(document.body.querySelectorAll('*')).filter(element =>
      scrollableOverflow.has(view.getComputedStyle(element).overflowY)));
    for (const element of candidates) if (!next.has(element)) observer.unobserve(element);
    for (const element of next) if (!candidates.has(element)) observer.observe(element);
    candidates = next;
    dirty = false;
  }
  function report() {
    timer = 0;
    const sourceID = sourceIdentity();
    if (!sourceID) return;
    if (dirty) rescan();
    const regions = [];
    for (const element of candidates) {
      if (!element.isConnected) continue;
      const region = visibleRegion(element, view);
      if (region) regions.push(region);
      if (regions.length === maximumRegions) break;
    }
    const signature = JSON.stringify(regions);
    if (force || last?.sourceID !== sourceID || last.signature !== signature) postRegions(regions, sourceID);
    last = { sourceID, signature };
    force = false;
  }
  function schedule(rescanCandidates = false, forcePost = false) {
    dirty ||= rescanCandidates;
    force ||= forcePost;
    if (!timer) timer = view.setTimeout(report, 16);
  }
  // Scroll only updates cached candidates and edge flags, not the DOM scan.
  document.addEventListener('scroll', () => schedule(), true);
  document.addEventListener('load', () => schedule(), true);
  document.fonts?.addEventListener('loadingdone', () => schedule());
  return { schedule };
}
