const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const root = document.documentElement;
const updateMotion = () => root.classList.toggle('motion-paused', reducedMotion.matches);
reducedMotion.addEventListener('change', updateMotion);
updateMotion();
if ('IntersectionObserver' in window) {
  root.classList.add('motion-ready');
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('in-view');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.08 });
  document.querySelectorAll('.reveal').forEach(element => observer.observe(element));
}
const tabs = [...document.querySelectorAll<HTMLButtonElement>('[data-scene]')];
function selectScene(tab: HTMLButtonElement, focus = false) {
  tabs.forEach(item => {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    const panel = document.getElementById(`panel-${item.dataset.scene}`);
    if (panel) panel.hidden = !selected;
  });
  if (focus) tab.focus();
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectScene(tab));
  tab.addEventListener('keydown', event => {
    let next: number | undefined;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) {
      event.preventDefault();
      selectScene(tabs[next], true);
    }
  });
});

let dateRefresh: ReturnType<typeof setTimeout>;
function updateCalendarDate() {
  clearTimeout(dateRefresh);
  const now = new Date();
  document.querySelectorAll('[data-live-month]').forEach(label => {
    label.textContent = now.toLocaleDateString(undefined, { month: 'short' }).toLocaleUpperCase();
  });
  document.querySelectorAll('[data-live-day]').forEach(label => {
    label.textContent = now.toLocaleDateString(undefined, { day: 'numeric' });
  });
  const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
  dateRefresh = setTimeout(updateCalendarDate, midnight.getTime() - now.getTime() + 100);
}
updateCalendarDate();
window.addEventListener('pageshow', updateCalendarDate);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') updateCalendarDate();
});
