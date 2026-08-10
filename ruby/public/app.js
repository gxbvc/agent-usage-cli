(function () {
  "use strict";

  var REFRESH_MS = 5 * 60 * 1000;
  var COUNTDOWN_TICK_MS = 30 * 1000;

  function formatDuration(ms) {
    if (ms <= 0) return "resetting…";
    var totalSeconds = Math.floor(ms / 1000);
    var days = Math.floor(totalSeconds / 86400);
    var hours = Math.floor((totalSeconds % 86400) / 3600);
    var minutes = Math.floor((totalSeconds % 3600) / 60);
    if (days > 0) return days + "d " + hours + "h";
    if (hours > 0) return hours + "h " + minutes + "m";
    return minutes + "m";
  }

  function tickCountdowns() {
    var nodes = document.querySelectorAll("[data-reset-at]");
    for (var i = 0; i < nodes.length; i += 1) {
      var node = nodes[i];
      var resetAt = new Date(node.getAttribute("data-reset-at")).getTime();
      if (isNaN(resetAt)) continue;
      node.textContent = formatDuration(resetAt - Date.now());
    }
  }

  function setupTooltips() {
    var tooltip = document.createElement("div");
    tooltip.className = "chart-tooltip";
    tooltip.setAttribute("hidden", "hidden");
    tooltip.setAttribute("role", "status");
    document.body.appendChild(tooltip);

    function place(x, y) {
      var offset = 14;
      var maxX = window.innerWidth - tooltip.offsetWidth - offset;
      var maxY = window.innerHeight - tooltip.offsetHeight - offset;
      tooltip.style.left = Math.min(x + offset, Math.max(offset, maxX)) + "px";
      tooltip.style.top = Math.min(y + offset, Math.max(offset, maxY)) + "px";
    }

    function show(target, x, y) {
      var text = target.getAttribute("data-tooltip");
      if (!text) return;
      tooltip.textContent = text;
      tooltip.removeAttribute("hidden");
      place(x, y);
    }

    function hide() {
      tooltip.setAttribute("hidden", "hidden");
    }

    document.addEventListener("pointerover", function (event) {
      var target = event.target.closest && event.target.closest(".chart-point");
      if (target) show(target, event.clientX, event.clientY);
    });
    document.addEventListener("pointermove", function (event) {
      if (tooltip.hasAttribute("hidden")) return;
      place(event.clientX, event.clientY);
    });
    document.addEventListener("pointerout", function (event) {
      var target = event.target.closest && event.target.closest(".chart-point");
      if (target) hide();
    });
    document.addEventListener(
      "focus",
      function (event) {
        var target = event.target.closest && event.target.closest(".chart-point");
        if (!target) return;
        var rect = target.getBoundingClientRect();
        show(target, rect.left, rect.top);
      },
      true,
    );
    document.addEventListener(
      "blur",
      function (event) {
        var target = event.target.closest && event.target.closest(".chart-point");
        if (target) hide();
      },
      true,
    );
  }

  function setupAutoRefresh() {
    setInterval(function () {
      if (document.visibilityState === "visible") window.location.reload();
    }, REFRESH_MS);
  }

  document.addEventListener("DOMContentLoaded", function () {
    setupTooltips();
    setupAutoRefresh();
    tickCountdowns();
    setInterval(tickCountdowns, COUNTDOWN_TICK_MS);
  });
})();
