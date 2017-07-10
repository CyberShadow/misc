// ==UserScript==
// @name        My Bugzilla helper
// @namespace   thecybershadow.net
// @include     https://issues.dlang.org/*
// @version     1
// @grant       none
// ==/UserScript==

(function() {
  var eSummary = document.getElementById('summary_alias_container');
  var eButton = document.createElement('a');
  var eId = document.getElementsByName('id')[0];
  eButton.href = 'emacs:///home/vladimir/work/extern/D/DBugTests/bugs/' + eId.value;
  eButton.innerHTML = '[◳]';
  eSummary.appendChild(eButton);
})();
