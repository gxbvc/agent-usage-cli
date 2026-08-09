(function () {
  "use strict";

  var DASHBOARD_URL = "http://127.0.0.1:4570/";
  var HEALTH_URL = "http://127.0.0.1:4570/health";
  var TIMEOUT_MS = 800;

  function showFallback() {
    var el = document.getElementById("fallback");
    if (el) el.hidden = false;
  }

  function checkAndRedirect() {
    var controller = new AbortController();
    var timer = setTimeout(function () {
      controller.abort();
    }, TIMEOUT_MS);

    fetch(HEALTH_URL, { signal: controller.signal, cache: "no-store" })
      .then(function (response) {
        clearTimeout(timer);
        if (response.ok) {
          window.location.replace(DASHBOARD_URL);
        } else {
          showFallback();
        }
      })
      .catch(function () {
        clearTimeout(timer);
        showFallback();
      });
  }

  document.addEventListener("DOMContentLoaded", function () {
    checkAndRedirect();
    var retry = document.getElementById("retry");
    if (retry) retry.addEventListener("click", checkAndRedirect);
  });
})();
