// ==UserScript==
// @name           Google Search Enhanced Keyboard Navigation
// @site           http://userscripts.org/scripts/show/43131
// @namespace      http://userscripts.org/users/82018
// @description    Enables Google's experimental keyboard shortcut navigation in search results, plus additional feature for jumping to Next/Previous result pages.
// @include        http://www.google.com/search?*
// @include        https://www.google.com/search?*
// @date           Fri Dec 18 19:43:51 HST 2009
//
// @version        1.3a
// @creator        Patrick C. McGinty
//
// @run-at         document-start
// @grant          GM_addStyle
// ==/UserScript==
//
// Quick Usage Instructions
// ========================
// This script provides global access to Google's experimental keyboard
// shortcut search feature on all search results. The original feature page is
// located at: http://www.google.com/experimental/
//
// In addition to the standard Google keyboard shortcuts (J,K,O,ENTER,/), this
// script also adds the 'H' and 'L' keys (lowercase) to quickly jump to the
// Previous and Next search results page.
//
// Notes For Current Users of Google Labs Experimental Search
// ==========================================================
// This script does not require you to join Google's "Experimental" search
// feature to work properly. If this feature was previously activated in your
// user account, then you should click the "Leave" option after installing the
// script. The option is located at: http://www.google.com/experimental/
//

// Google Keyboard Shortcut JS code
//var shortcut_js = "http://google.com/js/shortcuts.5.js"

var doc_items = "/html/body/div[@id='cnt']/table/tbody/tr/td/table"
var nav_items = "/html/body/div[@id='cnt']/*/table[@id='nav']/tbody/tr"
var prev_item = nav_items + "/td[1]/a"
var next_item = nav_items + "/td[last()]/a"

// Force loading of Google Shortcuts JS functions
/*function addJavaScript( js, onload ) {
   var head, ref;
   head = document.getElementsByTagName('head')[0];
   if (!head) { return; }
   script = document.createElement('script');
   script.type = 'text/javascript';
   script.src = js;
   script.addEventListener( "load", onload, false );
   head.appendChild(script);
}*/

// Keypress handler function
function key_event( e ) {
   // ignore meta keys
   if (e.ctrlKey || e.altKey || e.metaKey)
      return;
   // ignore when focus is on search box
   // note: unsafeWindow.sc is the reference to the Google container for all
   // code from shortcuts.5.js. The variable 'a' is the position of the results
   // cursor. When the position is <0, the user may be typing a search string,
   // so do not interpret a keypress.
   //if (unsafeWindow.sc.a < 0)
   //   return;

   // reports that the above code does not work all the time. the following was
   // addded as a secondary check
   // from http://www.openjs.com/scripts/events/keyboard_shortcuts/shortcut.js
   var element;
   if(e.target) element=e.target;
   else if(e.srcElement) element=e.srcElement;
   if(element.nodeType==3) element=element.parentNode;
   if(element.tagName == 'INPUT' || element.tagName == 'TEXTAREA') return;

   // not all browsers support these properties
   var code = e.charCode || e.keyCode;
   switch (code) {
   case 104: // 'h' key
      // load previous search results
      prev = document.evaluate( prev_item, document, null,
               XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null )
               .snapshotItem(0);
      if (prev) location.href=prev.href
      break;
   case 108: // 'l' key
      // load next search results
      next = document.evaluate( next_item, document, null,
               XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null )
               .snapshotItem(0);
      if (next) location.href=next.href
      break;
   }
}

// Add new features to 'shortcuts doc' page text
function add_doc() {
   var tbl, row;
   tbl = document.evaluate( doc_items, document, null,
         XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null )
         .snapshotItem(0);
   if (!tbl)
      return;
   row = tbl.insertRow(3);
   row.innerHTML="<th>L</th><td>Opens the next results page.</td>";
   row = tbl.insertRow(1);
   row.innerHTML="<th>H</th><td>Opens the previous results page.</td>";
}

function shortcut_onload() {
   // set new keypress handler
   document.addEventListener( 'keypress', key_event, false );
   // update page text
   add_doc();
}

// shift search results to the right
//document.getElementById('res').style.marginLeft = '1.1em';
//GM_addStyle( '#res { margin-left: 1.1em ! important; }' );
// load Google Shortctus JS code
//addJavaScript( shortcut_js, shortcut_onload );
//document.getElementById('res').style.marginLeft = '1.1em';

// -------------------------------------------------------------------------------

var sc = {};
sc.results = [];
sc.a = -1;
sc.p = -1;
sc.j = false;
sc.G = false;
sc.initialize = function () {
    //var a = document.getElementById("tads");
    //a && sc.addResults(a.childNodes);
    var b = document.getElementById("res");
    sc.addResults(b.childNodes);
    sc.P();
    //sc.createHelpBlock(a || b);
    sc.queryInputs = sc.getQueryInputs();
    for (var c = 0; c < sc.queryInputs.length; c++) {
        //sc.queryInputs[c].onfocus = sc.handleFocus;
        sc.queryInputs[c].addEventListener('focus', sc.handleFocus);
        sc.queryInputs[c].onblur = sc.handleBlur
    }
    document.onkeypress = sc.handleKeyPress;
    document.onkeydown = sc.handleKeyDown;
    document.onkeyup = sc.handleKeyUp;
    var d = window.location.hash,
        f = d ? parseInt(/[#]i=(-?\d*)/.exec(d)[1], 10) : 0;
    sc.selectResult(f == -1 ? sc.resultCount - 1 : f)
};
sc.addResults = function (a) {
    for (var b = 0; b < a.length; b++) {
        if (sc.canBeResult(a[b])) if (sc.addPossibleResult(sc.createResult(a[b]))) continue;
        a[b].hasChildNodes() && sc.addResults(a[b].childNodes)
    }
};
sc.addPossibleResult = function (a) {
    if (a.container.tagName == "LI" && /\bta.\b/.test(a.container.className)) {
        sc.addResult(a);
        sc.G = true;
        return true
    }
    if (a.container.className == "p") {
        a.container = a.container.previousSibling;
        sc.addResult(a);
        return true
    }
    if ((a.container.tagName == "DIV" || a.container.tagName == "LI" || a.container.tagName == "P") && /\bg\b/.test(a.container.className)) {
        sc.addResult(a);
        return true
    }
    if (a.container.tagName == "H2" && a.container.className == "r") {
        sc.addResult(a);
        return true
    }
    if (a.container.tagName == "P" && a.container.className == "e") {
        sc.addResult(a);
        return true
    }
    return false
};
sc.canBeResult = function (a) {
    return (a.tagName == "DIV" || a.tagName == "LI" || a.tagName == "P" || a.tagName == "H2") && a.getElementsByTagName("A").length > 0 || a.tagName == "A"
};
sc.s = function (a, b) {
    var c = document.createElement("TD");
    c.style.backgroundColor = b;
    if (a) c.width = a;
    c.innerHTML = "&nbsp;";
    return c
};
/*sc.createHelpBlock = function (a) {
    var b = document.getElementById("mbEnd");
    if (b) {
        var c = b.insertRow(0);
        c.appendChild(sc.getHelpText())
    } else {
        var d = document.createElement("TABLE");
        d.className = "mbEnd";
        d.width = "25%";
        d.border = "0";
        d.style.backgroundColor = "#ffffff";
        d.align = "right";
        d.cellPadding = "0";
        d.cellSpacing = "0";
        var c = d.insertRow(0);
        c.appendChild(sc.s());
        c.appendChild(sc.getHelpText());
        a.parentNode.insertBefore(d, a)
    }
};
sc.getHelpText = function () {
    var a = document.createElement("TD");
    a.className = "std";
    a.style.borderLeft = "1px solid #c9d7f1";
    a.style.paddingLeft = "0.3em";
    a.innerHTML = '<center class=f>Keyboard Shortcuts<br><br></center><table border=0 class="lg std"><tr><td>Key</td><td>Action</td></tr><tr><th>J</th><td>Selects the next result.</td></tr><tr><th>K</th><td>Selects the previous result.</td></tr><tr><th>O</th><td>Opens the selected result.</td></tr><tr><th>&lt;Enter&gt;</th><td>Opens the selected result.</td></tr><tr><th>/</th><td>Puts the cursor in the search box.</td></tr><tr><th>&lt;Esc&gt;</th><td>Removes the cursor from the search box.</td></tr></table><br>';
    return a
};*/
sc.createChevron = function (a) {
    var b = document.createElement("img");
    b.src = "/images/chevron.gif";
    b.style.visibility = "hidden";
    b.style.position = "absolute";
    //b.style.left = "210px";
    b.style.left = "-14px";
    b.style.marginTop = "4px";
    a.style.position = 'relative';
    a.insertBefore(b, a.firstChild)
};
sc.createResult = function (a) {
    return {
        container  : a,
        linkElement: a.tagName == "A" ? a : a.getElementsByTagName("A")[0]
    }
};
sc.addResult = function (a) {
    sc.createChevron(a.container);
    sc.results.push(a)
};
sc.P = function () {
    for (var a = 0; a < sc.results.length; a++) {
        sc.results[a].container.H = a;
        sc.results[a].container.onclick = sc.handleResultClick
    }
    sc.resultCount = sc.results.length
};
sc.handleResultClick = function () {
    sc.selectResult(this.H)
};
sc.handleFocus = function () {
    //sc.selectResult(-1)
};
sc.handleBlur = function () {
    sc.selectResult(sc.p)
};
sc.handleKeyDown = function (a) {
    a = a || window.event;
    if (a.ctrlKey || a.altKey || a.metaKey) return;
    var b = a.target || a.srcElement;
    if (b.tagName == "INPUT") {
        if (b.name == "q" && a.keyCode == 27) {
            b.value = sc.Q();
            b.blur();
            return sc.k(a)
        }
        return
    }
    if (a.keyCode == 13 || a.keyCode == 79) if (sc.a >= 0 && sc.a < sc.resultCount) {
        if (a.shiftKey) window.open(sc.results[sc.a].linkElement.href, "_blank");
        else {
            //window.location.replace("#i=" + sc.a);
            window.location = sc.results[sc.a].linkElement.href
        }
        return sc.k(a)
    }
};
sc.handleKeyUp = function () {
    sc.j = false
};
sc.handleKeyPress = function (a) {
    a = a || window.event;
    if (a.ctrlKey || a.altKey || a.metaKey) return;
    var b = a.target || a.srcElement;
    if (b.tagName == "INPUT") return;
    var c = a.charCode || a.keyCode;
    switch (c) {
    case 106:
        sc.o(1);
        break;
    case 107:
        sc.o(-1);
        break;
    case 47:
        sc.R();
        break;
    default:
        return
    }
    return sc.k(a)
};
sc.R = function () {
    var a = sc.queryInputs[0];
    a.focus();
    sc.S(a, 0, a.value.length)
};
sc.S = function (a, b, c) {
    if (a.setSelectionRange) a.setSelectionRange(b, c);
    else {
        var d = a.createTextRange();
        d.moveStart("character", b);
        d.moveEnd("character", c);
        d.select()
    }
};
sc.o = function (a) {
    if (a < 0 && sc.a + a >= 0 || a > 0 && sc.a + a < sc.resultCount) sc.selectResult(sc.a + a);
    else if (a > 0 && sc.a + a >= sc.resultCount) sc.L();
    else a < 0 && sc.a + a < 0 && sc.M()
};
sc.n = function (a) {
    if (sc.j) return;
    sc.j = true;
    //window.location.replace("#i=" + sc.a);
    window.location = a
};
sc.L = function () {
    var a = document.getElementById("nn");
    a != null && sc.n(a.parentNode.href)
};
sc.M = function () {
    var a = document.getElementById("np");
    a != null && sc.n(a.parentNode.href + "#i=-1")
};
sc.selectResult = function (a) {
    var b = null;
    if (sc.a != -1) b = sc.results[sc.a].container.firstChild;
    if (a == -1) {
        if (sc.a >= 0 && sc.a < sc.resultCount) b.style.visibility = "hidden";
        sc.a = -1;
        return
    }
    if (a < 0 || a >= sc.resultCount) return;
    if (sc.a >= 0 && sc.a < sc.resultCount) b.style.visibility = "hidden";
    var c = sc.a;
    sc.p = sc.a = a;
    var d = sc.results[sc.a].container;
    b = d.firstChild;
    b.style.visibility = "visible";
    sc.N(d, c < sc.a)
};
sc.N = function (a, b) {
    var c = sc.w(),
        d = sc.z(),
        f = c + d,
        e = sc.v(a),
        g = a.offsetHeight,
        i = e + g,
        h = c;
    if (e < c) h = b ? e : sc.a == 0 ? e - d / 2 + g : e - d / 2;
    else if (i > f) h = b ? sc.a == sc.resultCount - 1 ? e - d / 2 + g : e - d / 2 : i - d;
    window.scrollTo(0, h)
};
sc.t = function (a) {
    return decodeURIComponent(a.replace(/[+]/g, "%20"))
};
sc.Q = function () {
    var a = window.location.search;
    return a ? sc.t(/[&?]q=([^&]*)/.exec(a)[1]) : ""
};
sc.getQueryInputs = function () {
    var a = [],
        b = document.getElementsByTagName("INPUT");
    for (var c = 0; c < b.length; c++) b[c].name == "q" && a.push(b[c]);
    return a
};
sc.k = function (a) {
    if (a.stopPropagation) {
        a.stopPropagation();
        a.preventDefault()
    }
    a.cancelBubble = true;
    a.returnValue = false;
    return false
};
sc.w = function () {
    return self.pageYOffset ? self.pageYOffset : document.documentElement && document.documentElement.scrollTop ? document.documentElement.scrollTop : document.body.scrollTop
};
sc.z = function () {
    return self.innerHeight ? self.innerHeight : document.documentElement && document.documentElement.clientHeight ? document.documentElement.clientHeight : document.body.clientHeight
};
sc.v = function (a) {
    var b = a.offsetTop;
    while (a = a.offsetParent) b += a.offsetTop;
    return b
};

addEventListener("DOMContentLoaded", function() { sc.initialize(); });

/*(function() {
	function hide(id) {
		var e = document.getElementById(id);
		if (e)
			e.parentNode.removeChild(e);
	};
	hide('taw');
})();*/

GM_addStyle('#taw, #bottomads { display: none; }');
