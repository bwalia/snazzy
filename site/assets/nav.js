// The site's top menu: dropdowns that open on click (and hover on desktop),
// close on Escape or a click elsewhere, and a menu button on narrow screens.
(function () {
  var nav = document.querySelector("header.nav");
  if (!nav) return;
  var menus = nav.querySelectorAll(".menu");
  function closeAll(except) {
    menus.forEach(function (m) {
      if (m !== except) { m.classList.remove("open"); m.querySelector("button").setAttribute("aria-expanded", "false"); }
    });
  }
  menus.forEach(function (m) {
    var b = m.querySelector("button");
    b.addEventListener("click", function (e) {
      e.stopPropagation();
      var open = !m.classList.contains("open");
      closeAll(m);
      m.classList.toggle("open", open);
      b.setAttribute("aria-expanded", String(open));
    });
  });
  var burger = nav.querySelector(".burger");
  if (burger) burger.addEventListener("click", function (e) {
    e.stopPropagation();
    var open = !nav.classList.contains("open");
    nav.classList.toggle("open", open);
    burger.setAttribute("aria-expanded", String(open));
  });
  document.addEventListener("click", function (e) {
    if (!nav.contains(e.target)) { closeAll(); nav.classList.remove("open"); if (burger) burger.setAttribute("aria-expanded", "false"); }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { closeAll(); nav.classList.remove("open"); }
  });
  // In-page links (e.g. #features) close the menu after jumping.
  nav.querySelectorAll(".links a").forEach(function (a) {
    a.addEventListener("click", function () { closeAll(); nav.classList.remove("open"); });
  });
})();
