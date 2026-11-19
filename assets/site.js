/* FLUXA — interactions du site de présentation.
   Toutes les valeurs affichées sont des données de démonstration générées localement. */
(function () {
  "use strict";

  var root = document.documentElement;
  root.classList.add("js");

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var fr1 = new Intl.NumberFormat("fr-FR", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  var fr = new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 1 });

  /* ---------- Menu mobile ---------- */
  var header = document.querySelector(".header");
  var menuBtn = document.getElementById("menu-btn");
  if (header && menuBtn) {
    var setMenu = function (open) {
      header.classList.toggle("is-open", open);
      menuBtn.setAttribute("aria-expanded", String(open));
      menuBtn.querySelector(".menu-btn__label").textContent = open ? "Fermer" : "Menu";
    };
    menuBtn.addEventListener("click", function () {
      setMenu(!header.classList.contains("is-open"));
    });
    header.querySelectorAll(".nav a").forEach(function (a) {
      a.addEventListener("click", function () { setMenu(false); });
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && header.classList.contains("is-open")) {
        setMenu(false);
        menuBtn.focus();
      }
    });
  }

  /* ---------- Pied de page : accordéon sur téléphone, colonnes ouvertes au-delà ---------- */
  var cols = document.querySelectorAll(".fcol");
  if (cols.length) {
    var wide = window.matchMedia("(min-width: 720px)");
    var syncCols = function () {
      cols.forEach(function (d) {
        var s = d.querySelector("summary");
        if (wide.matches) {
          d.open = true;
          s.tabIndex = -1;
        } else {
          d.open = false;
          s.removeAttribute("tabindex");
        }
      });
    };
    cols.forEach(function (d) {
      d.querySelector("summary").addEventListener("click", function (e) {
        if (wide.matches) e.preventDefault();
      });
    });
    if (wide.addEventListener) wide.addEventListener("change", syncCols);
    syncCols();
  }

  /* ---------- Année du copyright ---------- */
  document.querySelectorAll("[data-year]").forEach(function (el) {
    el.textContent = String(new Date().getFullYear());
  });

  /* ---------- Démonstration : tableau de bord ---------- */
  var canvas = document.getElementById("flux");
  if (canvas && canvas.getContext) {
    var ctx = canvas.getContext("2d");
    var css = getComputedStyle(root);
    var color = function (name) { return css.getPropertyValue(name).trim(); };
    var C = { down: color("--down"), up: color("--up"), grid: color("--line-soft"), text: color("--text-3"), bg: color("--ink-0") };

    var N = 30;        // points visibles
    var MAX = 60;      // haut de l'échelle, en Mb/s
    var BASE_D = 42.8;
    var BASE_U = 8.4;
    var d = BASE_D, u = BASE_U;
    var down = [], up = [];
    var clamp = function (v, a, b) { return Math.min(b, Math.max(a, v)); };

    var step = function () {
      d = clamp(d + (Math.random() - 0.5) * 8 + (BASE_D - d) * 0.18, 26, 55);
      u = clamp(u + (Math.random() - 0.5) * 2.4 + (BASE_U - u) * 0.2, 4.5, 13);
      down.push(d);
      up.push(u);
      if (down.length > N + 2) { down.shift(); up.shift(); }
    };
    for (var i = 0; i < N + 1; i++) step();
    down.push(BASE_D); up.push(BASE_U); down.shift(); up.shift();
    down.push(BASE_D); up.push(BASE_U);
    d = BASE_D; u = BASE_U;

    var W = 0, H = 0;
    var resize = function () {
      var r = canvas.getBoundingClientRect();
      var dpr = Math.min(window.devicePixelRatio || 1, 3);
      W = r.width; H = r.height;
      canvas.width = Math.round(W * dpr);
      canvas.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };

    var PAD_T = 6, PAD_R = 7, PAD_B = 3;
    var y = function (v) { return H - PAD_B - (v / MAX) * (H - PAD_T - PAD_B); };

    var trace = function (arr, t) {
      var dx = (W - PAD_R) / (N - 1);
      ctx.beginPath();
      for (var k = 0; k < arr.length; k++) {
        var x = (k - 1 - t) * dx;
        if (k === 0) ctx.moveTo(x, y(arr[k])); else ctx.lineTo(x, y(arr[k]));
      }
    };

    var draw = function (t) {
      if (!W) return;
      ctx.clearRect(0, 0, W, H);

      // Grille : 20 et 40 Mb/s
      ctx.font = "10px " + (color("--font-data") || "monospace");
      ctx.textBaseline = "bottom";
      [20, 40].forEach(function (g) {
        ctx.strokeStyle = C.grid;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, Math.round(y(g)) + 0.5);
        ctx.lineTo(W, Math.round(y(g)) + 0.5);
        ctx.stroke();
        ctx.fillStyle = C.text;
        ctx.fillText(String(g), 0, y(g) - 2);
      });

      ctx.save();
      ctx.beginPath();
      ctx.rect(0, 0, W - PAD_R, H);
      ctx.clip();

      // Descendant : aire + trait
      trace(down, t);
      ctx.lineTo(W + 40, H); ctx.lineTo(-40, H); ctx.closePath();
      var grad = ctx.createLinearGradient(0, 0, 0, H);
      grad.addColorStop(0, C.down + "55");
      grad.addColorStop(1, C.down + "00");
      ctx.fillStyle = grad;
      ctx.fill();

      ctx.lineJoin = "round"; ctx.lineCap = "round"; ctx.lineWidth = 2;
      trace(down, t); ctx.strokeStyle = C.down; ctx.stroke();
      ctx.lineWidth = 1.5;
      trace(up, t); ctx.strokeStyle = C.up; ctx.stroke();
      ctx.restore();

      // Points courants, sur le bord droit
      var last = down.length - 1;
      var curD = down[last - 1] + (down[last] - down[last - 1]) * t;
      var curU = up[last - 1] + (up[last] - up[last - 1]) * t;
      [[curD, C.down, 3.5], [curU, C.up, 3]].forEach(function (p) {
        ctx.beginPath();
        ctx.arc(W - PAD_R, y(p[0]), p[2], 0, Math.PI * 2);
        ctx.fillStyle = p[1];
        ctx.fill();
        ctx.lineWidth = 2;
        ctx.strokeStyle = C.bg;
        ctx.stroke();
      });
    };

    var elDown = document.getElementById("d-down");
    var elUp = document.getElementById("d-up");
    var elLat = document.getElementById("d-lat");
    var elJit = document.getElementById("d-jit");
    var ticks = 0;

    var tick = function () {
      // Le point courant vient d'atteindre la dernière mesure : on l'affiche, puis on prépare la suivante.
      if (elDown) elDown.textContent = fr1.format(d);
      if (elUp) elUp.textContent = fr1.format(u);
      step();
      ticks++;
      // La latence et la gigue sont mesurées toutes les 5 secondes, comme dans l'app.
      if (ticks % 5 === 0) {
        if (elLat) elLat.textContent = String(Math.round(24 + Math.random() * 9));
        if (elJit) elJit.textContent = String(Math.round(2 + Math.random() * 4));
      }
    };

    resize();
    draw(1);

    if (window.ResizeObserver) {
      new ResizeObserver(function () { resize(); draw(1); }).observe(canvas);
    } else {
      window.addEventListener("resize", function () { resize(); draw(1); });
    }

    if (!reduceMotion) {
      var visible = true;
      var t0 = null;
      var running = false;
      var frame = function (now) {
        if (!visible || document.hidden) { running = false; t0 = null; return; }
        if (t0 === null) t0 = now;
        var t = (now - t0) / 1000;
        if (t >= 1) { tick(); t0 = now; t = 0; }
        draw(t);
        requestAnimationFrame(frame);
      };
      var start = function () {
        if (running || !visible || document.hidden) return;
        running = true;
        // On repart d'un état posé : le dernier point est déjà à l'écran.
        step();
        requestAnimationFrame(frame);
      };
      if (window.IntersectionObserver) {
        new IntersectionObserver(function (entries) {
          visible = entries[0].isIntersecting;
          start();
        }).observe(canvas);
      }
      document.addEventListener("visibilitychange", start);
      start();
    }
  }

  /* ---------- Démonstration : profils, configuré ou appliqué ---------- */
  var lab = document.getElementById("lab");
  if (lab) {
    // Préréglages de la V1. null = sans plafond configuré.
    var PROFILES = [
      { name: "Économie", down: 1, up: 0.5 },
      { name: "Très lent", down: 2, up: 1 },
      { name: "Navigation", down: 5, up: 2 },
      { name: "Standard", down: 15, up: 5 },
      { name: "Streaming", down: 25, up: 10 },
      { name: "Performance", down: 50, up: 20 },
      { name: "Maximum", down: null, up: null }
    ];
    var MEASURED = { down: 42.8, up: 8.4 }; // débit de démonstration
    var chips = lab.querySelectorAll(".chip");
    var fillD = document.getElementById("m-down");
    var fillU = document.getElementById("m-up");
    var valD = document.getElementById("v-down");
    var valU = document.getElementById("v-up");
    var effect = document.getElementById("lab-effect");

    // Échelle logarithmique de 0,1 à 1 000 Mb/s : la plage réglable dans l'app.
    var pos = function (v) { return ((Math.log(v) / Math.LN10 + 1) / 4) * 100; };
    var mb = function (v) { return fr.format(v) + " Mb/s"; };

    var setMeter = function (fill, val, v) {
      if (v === null) {
        fill.style.width = "100%";
        fill.classList.add("is-open");
        val.textContent = "Sans plafond";
      } else {
        fill.style.width = pos(v).toFixed(1) + "%";
        fill.classList.remove("is-open");
        val.textContent = mb(v);
      }
    };

    var describe = function (p) {
      if (p.down === null) {
        return "Aucun plafond configuré : le débit mesuré, <strong>" + mb(MEASURED.down) + "</strong> en descendant, resterait inchangé.";
      }
      var parts = [];
      parts.push(p.down < MEASURED.down
        ? "le descendant passerait de <strong>" + mb(MEASURED.down) + "</strong> à <strong>" + mb(p.down) + "</strong>"
        : "le descendant resterait à <strong>" + mb(MEASURED.down) + "</strong>, sous le plafond");
      parts.push(p.up < MEASURED.up
        ? "le montant de <strong>" + mb(MEASURED.up) + "</strong> à <strong>" + mb(p.up) + "</strong>"
        : "le montant resterait à <strong>" + mb(MEASURED.up) + "</strong>, sous le plafond");
      return "Simulation sur le débit mesuré : " + parts.join(" et ") + ".";
    };

    var select = function (index) {
      var p = PROFILES[index];
      chips.forEach(function (c, k) { c.setAttribute("aria-pressed", String(k === index)); });
      setMeter(fillD, valD, p.down);
      setMeter(fillU, valU, p.up);
      effect.innerHTML = describe(p);
    };

    chips.forEach(function (c, k) {
      c.addEventListener("click", function () { select(k); });
    });
    select(4);
  }
})();
