// ==UserScript==
// @name        NoMergeButton
// @namespace   http://thecybershadow.net
// @description Disable merge button on GitHub
// @include     https://github.com/D-Programming-Language/dmd*
// @include     https://github.com/D-Programming-Language/phobos*
// @include     https://github.com/D-Programming-Language/druntime*
// @version     1
// @grant       none
// ==/UserScript==

function addGlobalStyle(css) {
    var head, style;
    head = document.getElementsByTagName('head')[0];
    if (!head) { return; }
    style = document.createElement('style');
    style.type = 'text/css';
    style.innerHTML = css;
    head.appendChild(style);
}

addGlobalStyle('.js-merge-branch-action::before { content: "DO NOT " }');
addGlobalStyle('.js-merge-branch-action::after { content: " here, use Auto Merge!" }');
addGlobalStyle('.js-merge-branch-action { color: #808080; }');
