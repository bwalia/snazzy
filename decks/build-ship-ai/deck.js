// 16:9 slides scaled to the window. Arrow keys / space / click to navigate.
const slides = [...document.querySelectorAll('.slide')];
// The counter is optional in index.html; add it if it's missing.
const counter = document.querySelector('.counter') ||
  document.body.appendChild(Object.assign(document.createElement('div'), { className: 'counter' }));
let current = Math.min(Number(location.hash.slice(1)) || 0, slides.length - 1);
function fit() {
  const s = Math.min(innerWidth / 1600, innerHeight / 900);
  slides.forEach(el => el.style.transform = `scale(${s})`);
}
function show(i) {
  current = Math.max(0, Math.min(i, slides.length - 1));
  slides.forEach((el, n) => el.classList.toggle('active', n === current));
  counter.textContent = `${current + 1} / ${slides.length}`;
  history.replaceState(null, '', '#' + current);
}
addEventListener('resize', fit);
addEventListener('keydown', e => {
  if (['ArrowRight', 'PageDown', ' '].includes(e.key)) show(current + 1);
  if (['ArrowLeft', 'PageUp'].includes(e.key)) show(current - 1);
});
addEventListener('click', () => show(current + 1));
window.snazzyDeck = { show, count: () => slides.length, current: () => current };
fit(); show(current);

